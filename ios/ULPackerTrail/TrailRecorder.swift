import CoreLocation
import Foundation
import Observation
import TripCore

/// Connects the phone's location updates to the recording logic in TripCore.
///
/// Kept deliberately small: it owns lifecycle and error surfacing, and forwards
/// every fix straight through. All of the judgement — what to keep, when to
/// flush, whether the walker has left the route — lives in `RecordingSession`
/// where it is tested without a device.
@MainActor
@Observable
final class TrailRecorder {
    enum Status: Equatable {
        case idle
        case needsPermission
        case recording
        case paused
        case finished(ActivityPackage)
        /// A start or resume that produced no session — there is nothing
        /// recording and nothing buffered to lose. Distinct from a write
        /// problem during a live walk, which is `writeError` below and never
        /// takes the transport controls away.
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var progress: RecordingSession.Progress?
    /// Set when the walker crosses into off-route; the UI clears it once shown.
    private(set) var pendingOffRouteAlert = false
    /// A save that failed while a walk was in progress — a full disk, a
    /// momentary I/O error. The walk keeps going and the fixes stay buffered in
    /// memory; this is a retryable warning, not the end of the session, and it
    /// must never be the only thing on screen. Nil when the last save succeeded.
    private(set) var writeError: String?

    let location = LocationProvider()

    let package: TripPackage
    private let index: RouteIndex
    private let notifier: TrailNotifier
    private var session: RecordingSession?
    /// Re-checks GPS freshness while nothing is arriving. Core Location can fall
    /// silent for minutes; without a nudge the last state would stand and the
    /// screen would keep claiming "on route". Foreground only — a suspended app
    /// runs no timers, which is the one gap that cannot be closed from here.
    private var freshnessTimer: Timer?

    /// Off-route thresholds come from the trip, so a broad waymarked path and a
    /// faint traverse can be judged differently. Invalid values in the package
    /// fall back to defaults inside the monitor's initialiser.
    private var configuration: RecordingSession.Configuration {
        .init(offRoute: .init(navigationDefaults: package.navigationDefaults))
    }

    /// Which trip this recorder walks. The coordinator uses it to keep exactly
    /// one walk alive and to refuse a second on a different trip.
    var tripId: String { package.tripId }

    /// A live session exists — recording, paused, or holding buffered fixes
    /// after a write hiccup. This is what must survive leaving the screen and
    /// what blocks starting a different walk.
    var isActive: Bool { session != nil }

    /// Where every session directory lives. Internal so the coordinator can scan
    /// it for an unfinished walk at launch.
    static var activitiesRoot: URL {
        URL.documentsDirectory.appendingPathComponent("activities", isDirectory: true)
    }

    init(package: TripPackage, notifier: TrailNotifier = SystemNotifier()) {
        self.package = package
        // Built once here rather than per fix: ~8560 edges, tens of
        // milliseconds, and then every query is essentially free.
        self.index = RouteIndex(segments: package.plannedRoute.segments)
        self.notifier = notifier
        location.onFix = { [weak self] fix in self?.handle(fix) }
    }

    var authorization: LocationProvider.Authorization { location.authorization }

    // MARK: - Control

    func start(stageId: String? = nil) {
        guard authorization == .whenInUse || authorization == .always else {
            location.requestAuthorization()
            status = .needsPermission
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: Self.activitiesRoot, withIntermediateDirectories: true
            )
            let config = location.nativeConfig
            session = try RecordingSession.start(
                package: package,
                index: index,
                in: Self.activitiesRoot,
                stageId: stageId,
                nativeConfig: .init(
                    desiredAccuracy: config.desiredAccuracy,
                    distanceFilterM: config.distanceFilterM,
                    activityType: config.activityType,
                    pausesAutomatically: config.pausesAutomatically,
                    allowsBackgroundUpdates: config.allowsBackgroundUpdates
                ),
                configuration: configuration
            )
            // Asked for now, at the start of the walk, so a later off-route alert
            // has permission to fire rather than raising a sheet at the worst
            // possible moment.
            notifier.requestAuthorization()
            PowerMonitor.shared.start()
            recordPower(force: true)
            location.startUpdates()
            startFreshnessTimer()
            status = .recording
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// Reopen a crashed session against this trip. The package must match the
    /// journal's — the coordinator guarantees that before calling — but the
    /// guard in TripCore is the real safety net, and if it ever fires the walk
    /// is left on disk untouched, never forced onto the wrong route.
    func resumeCrashedSession(_ journal: ActivityJournal) {
        do {
            session = try RecordingSession.resume(
                journal: journal, package: package, index: index, configuration: configuration
            )
            notifier.requestAuthorization()
            PowerMonitor.shared.start()
            recordPower(force: true)
            location.startUpdates()
            startFreshnessTimer()
            status = .recording
        } catch {
            // Nothing was consumed and the journal is intact on disk. Surface it
            // as a start failure the user can dismiss; the walk stays put for
            // another attempt or an export.
            status = .failed(String(describing: error))
        }
    }

    func pause() {
        guard let session else { return }
        do {
            // Read the battery one last time before the gap, so the stretch up
            // to the pause is fully measured, then stop the monitor for the
            // duration — a paused walk is not drawing power on our account.
            recordPower(force: true)
            try session.pause()
            location.stopUpdates()
            stopFreshnessTimer()
            PowerMonitor.shared.stop()
            writeError = nil
            status = .paused
        } catch {
            // The flush that a pause performs failed. Keep recording rather than
            // half-pausing: the fixes are still buffered and Finish will try to
            // save them again.
            writeError = Self.describe(error)
        }
    }

    func resume() {
        guard let session else { return }
        session.resumeRecording()
        // Restart the monitor and open a fresh segment with a boundary reading,
        // so the report excludes the paused interval between this and the last
        // pre-pause sample rather than counting a lunch or a night as drain.
        PowerMonitor.shared.start()
        recordPower(force: true, boundary: true)
        location.startUpdates()
        startFreshnessTimer()
        status = .recording
    }

    func finish() {
        guard let session else { return }
        do {
            location.stopUpdates()
            stopFreshnessTimer()
            // One last reading before the session closes, so the final stretch
            // is inside the measurement rather than after it.
            recordPower(force: true)
            let activity = try session.finish()
            PowerMonitor.shared.stop()
            self.session = nil
            writeError = nil
            status = .finished(activity)
        } catch {
            // The save failed but the journal is intact and the session is still
            // held. Keep the transport controls — Finish stays retryable — and
            // show the problem rather than collapsing to a delete-only screen.
            writeError = Self.describe(error)
        }
    }

    /// Try the save again after a `writeError`, without ending the walk.
    func retrySave() {
        guard let session else { return }
        do {
            try session.flush()
            writeError = nil
        } catch {
            writeError = Self.describe(error)
        }
    }

    /// Dismiss a start/resume failure and return to idle. The on-disk journal,
    /// if any, is left alone — this never deletes a walk.
    func dismissFailure() {
        guard case .failed = status else { return }
        status = .idle
    }

    /// Throw the walk away — an accidental start, not a finished day.
    ///
    /// Only ever reached through a button that says so. "Start another" used to
    /// call this, which meant the tap that cleared the summary also deleted the
    /// walk it was summarising.
    func discard() {
        location.stopUpdates()
        stopFreshnessTimer()
        PowerMonitor.shared.stop()
        try? session?.discard()
        session = nil
        progress = nil
        writeError = nil
        status = .idle
    }

    /// Clear the finished summary and go back to idle, keeping the walk.
    func clearFinished() {
        guard case .finished = status else { return }
        session = nil
        progress = nil
        writeError = nil
        status = .idle
    }

    /// Commit whatever is buffered — called when the app is about to lose
    /// control, which is the last chance to shrink what a kill would cost.
    func flushForBackgrounding() {
        try? session?.flush()
    }

    func clearOffRouteAlert() {
        pendingOffRouteAlert = false
    }

    /// Offer the session a battery reading. Throttled inside the monitor, so
    /// calling it on every fix costs a property read and nothing else.
    private func recordPower(force: Bool = false, boundary: Bool = false) {
        guard let sample = PowerMonitor.shared.sample(force: force, boundary: boundary) else { return }
        session?.receive(power: sample)
    }

    // MARK: - Fixes

    private func handle(_ fix: CLLocation) {
        guard let session else { return }
        do {
            let update = try session.receive(
                lat: fix.coordinate.latitude,
                lng: fix.coordinate.longitude,
                at: fix.timestamp,
                horizontalAccuracyM: fix.horizontalAccuracy,
                altitude: fix.altitude,
                verticalAccuracyM: fix.verticalAccuracy,
                // Core Location reports negative for "not available"; passing
                // that through as data would be a lie about the observation.
                speed: fix.speed >= 0 ? fix.speed : nil,
                bearing: fix.course >= 0 ? fix.course : nil
            )
            progress = update
            recordPower()
            if let update { fireAlerts(for: update) }
            // A fix arrived and saved: any earlier write warning has cleared
            // itself, so stop showing it.
            if writeError != nil { writeError = nil }
        } catch {
            // A write failure mid-walk is worth surfacing, but not worth tearing
            // the session down for: the fix is buffered in memory and the next
            // flush may well succeed. Keep recording, show a retryable warning.
            writeError = Self.describe(error)
        }
    }

    /// Raise the alerts a fix (or a freshness tick) has just decided are due.
    ///
    /// Off-route sets the in-app flag *and* posts a notification: the flag shows
    /// an alert if the screen is on, the notification carries it when it is not.
    /// No-fix only posts — its status is on the screen already, and the value of
    /// the notification is entirely in the pocket case.
    private func fireAlerts(for progress: RecordingSession.Progress) {
        if progress.shouldAlertOffRoute {
            pendingOffRouteAlert = true
            notifier.notifyOffRoute()
        }
        if progress.shouldAlertNoFix {
            notifier.notifyNoFix()
        }
        if progress.shouldAlertWrongWay {
            notifier.notifyWrongWay()
        }
    }

    // MARK: - Freshness

    private func startFreshnessTimer() {
        freshnessTimer?.invalidate()
        // A slow tick: the no-fix threshold is minutes, so checking every twenty
        // seconds catches it promptly without waking anything of consequence.
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFreshness() }
        }
    }

    private func stopFreshnessTimer() {
        freshnessTimer?.invalidate()
        freshnessTimer = nil
    }

    private func checkFreshness() {
        guard let session else { return }
        let now = Date()
        // Silence under a distance filter is usually just standing still. Ask
        // the receiver before the no-fix judgement gets a chance to cry wolf: a
        // working GPS answers within seconds and the stop stays a stop.
        if session.needsFreshnessProbe(at: now) { location.probe() }
        guard let update = session.evaluate(at: now) else { return }
        progress = update
        fireAlerts(for: update)
    }

    /// A short, human line for an error banner. The raw `Error` description is
    /// for the log; this is what a cold, tired walker reads.
    private static func describe(_ error: Error) -> String {
        "Couldn't save the last stretch. It's still held in memory — tap Retry, or Finish to try saving everything."
    }
}
