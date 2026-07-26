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
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var progress: RecordingSession.Progress?
    /// Set when the walker crosses into off-route; the UI clears it once shown.
    private(set) var pendingOffRouteAlert = false

    let location = LocationProvider()

    private let package: TripPackage
    private let index: RouteIndex
    private var session: RecordingSession?

    private static var activitiesRoot: URL {
        URL.documentsDirectory.appendingPathComponent("activities", isDirectory: true)
    }

    init(package: TripPackage) {
        self.package = package
        // Built once here rather than per fix: ~8560 edges, tens of
        // milliseconds, and then every query is essentially free.
        self.index = RouteIndex(segments: package.plannedRoute.segments)
        location.onFix = { [weak self] fix in self?.handle(fix) }
    }

    var authorization: LocationProvider.Authorization { location.authorization }

    /// A session left behind by a crash, if there is one. Checked at launch so
    /// an interrupted walk can be continued rather than silently lost.
    func pendingRecovery() -> ActivityJournal? {
        try? ActivityJournal.pendingSessions(in: Self.activitiesRoot).first
    }

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
                )
            )
            PowerMonitor.shared.start()
            recordPower(force: true)
            location.startUpdates()
            status = .recording
        } catch {
            status = .failed(String(describing: error))
        }
    }

    func resumeCrashedSession(_ journal: ActivityJournal) {
        do {
            session = try RecordingSession.resume(journal: journal, package: package, index: index)
            PowerMonitor.shared.start()
            recordPower(force: true)
            location.startUpdates()
            status = .recording
        } catch {
            status = .failed(String(describing: error))
        }
    }

    func pause() {
        guard let session else { return }
        do {
            try session.pause()
            location.stopUpdates()
            status = .paused
        } catch {
            status = .failed(String(describing: error))
        }
    }

    func resume() {
        guard let session else { return }
        session.resumeRecording()
        location.startUpdates()
        status = .recording
    }

    func finish() {
        guard let session else { return }
        do {
            location.stopUpdates()
            // One last reading before the session closes, so the final stretch
            // is inside the measurement rather than after it.
            recordPower(force: true)
            status = .finished(try session.finish())
            PowerMonitor.shared.stop()
            self.session = nil
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// Throw the walk away — an accidental start, not a finished day.
    ///
    /// Only ever reached through a button that says so. "Start another" used to
    /// call this, which meant the tap that cleared the summary also deleted the
    /// walk it was summarising.
    func discard() {
        location.stopUpdates()
        PowerMonitor.shared.stop()
        try? session?.discard()
        session = nil
        progress = nil
        status = .idle
    }

    /// Clear the finished summary and go back to idle, keeping the walk.
    func clearFinished() {
        guard case .finished = status else { return }
        session = nil
        progress = nil
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
    private func recordPower(force: Bool = false) {
        guard let sample = PowerMonitor.shared.sample(force: force) else { return }
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
            if update?.shouldAlertOffRoute == true { pendingOffRouteAlert = true }
        } catch {
            // A write failure mid-walk is worth surfacing, but not worth
            // tearing down the session for: fixes stay buffered in memory and
            // the next flush may well succeed.
            status = .failed(String(describing: error))
        }
    }
}
