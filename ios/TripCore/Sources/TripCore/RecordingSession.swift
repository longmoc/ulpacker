import Foundation

/// Ties the recording pieces together: journal, matcher, off-route monitor.
///
/// Everything here is driven by `receive(_:)`, which the app calls once per
/// Core Location fix. Keeping the orchestration in TripCore rather than in the
/// app target means the interesting behaviour — buffering, flush timing,
/// pause/resume, crash recovery — is testable with synthetic fixes on a Mac,
/// and only the `CLLocationManager` plumbing needs a phone.
///
/// **Matching runs on every fix, including in the background.** An earlier plan
/// said to defer it until the app was foregrounded, on the assumption it was
/// expensive; measured on the real route it costs 0.01 ms, and deferring it
/// would have broken the feature that matters most — an off-route alert while
/// the phone is in a pocket with the screen off.
@MainActor
public final class RecordingSession {
    public struct Configuration: Sendable {
        /// Flush the buffer after this many fixes…
        public var flushEveryFixes: Int
        /// …or after this long, whichever comes first. The pair bounds what a
        /// sudden kill can cost: at a walking pace this is roughly 70 m of
        /// track, against the flash writes and wakeups of saving every fix.
        public var flushInterval: TimeInterval
        public var matcher: RouteMatcher.Configuration
        public var offRoute: OffRouteMonitor.Configuration

        public init(
            flushEveryFixes: Int = 10,
            flushInterval: TimeInterval = 60,
            matcher: RouteMatcher.Configuration = .init(),
            offRoute: OffRouteMonitor.Configuration = .init()
        ) {
            self.flushEveryFixes = flushEveryFixes
            self.flushInterval = flushInterval
            self.matcher = matcher
            self.offRoute = offRoute
        }
    }

    /// What the UI and the notification layer read after each fix.
    public struct Progress: Sendable, Equatable {
        public let routeDistanceM: Double
        public let remainingM: Double
        public let offsetM: Double
        /// Position snapped onto the route, not the raw fix.
        ///
        /// This is what a map should show: drawing the raw observation puts the
        /// walker beside the line whenever GPS is noisy, which reads as a bug
        /// in the app rather than as noise in the receiver. `offsetM` already
        /// carries how far the raw fix actually was.
        public let lat: Double
        public let lng: Double
        public let confidence: RouteMatcher.Confidence
        public let offRouteState: OffRouteMonitor.State
        /// Set on the transition into off-route — the one moment to notify.
        public let shouldAlertOffRoute: Bool
        public let nextCheckpoint: TripPackage.Checkpoint?
        public let distanceToNextCheckpointM: Double?
        public let fixCount: Int
        public let rejectedFixCount: Int
    }

    public enum State: String, Sendable {
        case recording
        case paused
        case finished
    }

    public private(set) var state: State = .recording
    public private(set) var progress: Progress?

    private let journal: ActivityJournal
    private let package: TripPackage
    private let index: RouteIndex
    private var matcher: RouteMatcher
    private var monitor: OffRouteMonitor
    private let configuration: Configuration

    private var buffer: [ActivityPackage.Fix] = []
    private var lastFlushAt: Date
    private var nextSequence: Int
    private var totalFixes: Int
    private var rejectedFixes = 0
    private let recoveredFromCrash: Bool

    // MARK: - Lifecycle

    /// Start a new session. The journal header is committed before this returns,
    /// so a crash on the first fix still leaves something recoverable.
    public static func start(
        package: TripPackage,
        index: RouteIndex,
        in root: URL,
        activityId: String = UUID().uuidString,
        stageId: String? = nil,
        nativeConfig: ActivityPackage.NativeConfig,
        startedAt: Date = Date(),
        configuration: Configuration = .init()
    ) throws -> RecordingSession {
        let journal = try ActivityJournal.create(
            in: root,
            session: .init(
                activityId: activityId,
                tripId: package.tripId,
                tripRevision: package.revision,
                stageId: stageId,
                startedAt: startedAt,
                nativeConfig: nativeConfig
            )
        )
        return RecordingSession(
            journal: journal,
            package: package,
            index: index,
            configuration: configuration,
            resumedFixes: [],
            recoveredFromCrash: false
        )
    }

    /// Reopen a session left behind by a crash, replaying what reached the disk
    /// so the matcher and the off-route state are not starting from nothing.
    public static func resume(
        journal: ActivityJournal,
        package: TripPackage,
        index: RouteIndex,
        configuration: Configuration = .init()
    ) throws -> RecordingSession {
        let existing = try journal.readFixes()
        return RecordingSession(
            journal: journal,
            package: package,
            index: index,
            configuration: configuration,
            resumedFixes: existing,
            recoveredFromCrash: true
        )
    }

    private init(
        journal: ActivityJournal,
        package: TripPackage,
        index: RouteIndex,
        configuration: Configuration,
        resumedFixes: [ActivityPackage.Fix],
        recoveredFromCrash: Bool
    ) {
        self.journal = journal
        self.package = package
        self.index = index
        self.configuration = configuration
        self.matcher = RouteMatcher(index: index, configuration: configuration.matcher)
        self.monitor = OffRouteMonitor(configuration: configuration.offRoute)
        self.lastFlushAt = journal.session.startedAt
        self.nextSequence = (resumedFixes.last?.seq ?? 0) + 1
        self.totalFixes = resumedFixes.count
        self.recoveredFromCrash = recoveredFromCrash

        // Replay only the last accepted position rather than every fix: the
        // matcher needs somewhere to start, not the whole history, and walking
        // thousands of stale fixes through the off-route monitor would raise
        // alerts about a deviation that happened hours ago.
        if let last = resumedFixes.last(where: { $0.isUsable(maxAccuracyM: configuration.matcher.maxAccuracyM) }),
           let projection = index.nearestExhaustive(lat: last.lat, lng: last.lng) {
            matcher.seed(routeDistanceM: projection.routeDistanceM, at: last.t)
        }
        rejectedFixes = resumedFixes.filter { !$0.isUsable(maxAccuracyM: configuration.matcher.maxAccuracyM) }.count
    }

    // MARK: - Recording

    /// Feed one observation. Returns the progress the UI should show, or nil
    /// while paused or finished.
    @discardableResult
    public func receive(
        lat: Double,
        lng: Double,
        at time: Date,
        horizontalAccuracyM: Double,
        altitude: Double? = nil,
        verticalAccuracyM: Double? = nil,
        speed: Double? = nil,
        bearing: Double? = nil
    ) throws -> Progress? {
        guard state == .recording else { return nil }

        let fix = ActivityPackage.Fix(
            seq: nextSequence,
            t: time,
            lat: lat,
            lng: lng,
            hAcc: horizontalAccuracyM,
            alt: altitude,
            vAcc: verticalAccuracyM,
            speed: speed,
            bearing: bearing
        )
        nextSequence += 1
        totalFixes += 1

        // Buffered, not written straight through: batching keeps flash writes
        // and their wakeups proportional to time rather than to every fix.
        // Every fix is buffered, including poor ones — a rejected fix is
        // evidence about the conditions and must survive to the diagnostics.
        buffer.append(fix)
        if !fix.isUsable(maxAccuracyM: configuration.matcher.maxAccuracyM) { rejectedFixes += 1 }

        if buffer.count >= configuration.flushEveryFixes
            || time.timeIntervalSince(lastFlushAt) >= configuration.flushInterval {
            try flush(at: time)
        }

        let match = matcher.match(fix)
        let update = monitor.update(match: match, accuracyM: horizontalAccuracyM, at: time)

        let next = package.checkpoints.first { Double($0.routeDistanceM) > match.routeDistanceM }
        let progress = Progress(
            routeDistanceM: match.routeDistanceM,
            remainingM: max(0, index.totalM - match.routeDistanceM),
            offsetM: match.offsetM,
            lat: match.lat,
            lng: match.lng,
            confidence: match.confidence,
            offRouteState: update.state,
            shouldAlertOffRoute: update.didEnterOffRoute,
            nextCheckpoint: next,
            distanceToNextCheckpointM: next.map { Double($0.routeDistanceM) - match.routeDistanceM },
            fixCount: totalFixes,
            rejectedFixCount: rejectedFixes
        )
        self.progress = progress
        return progress
    }

    /// Commit whatever is buffered. Called on the flush schedule, and by the
    /// app whenever it is about to lose control — backgrounding, termination
    /// warnings, low power.
    public func flush(at time: Date = Date()) throws {
        guard !buffer.isEmpty else { return }
        try journal.append(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
        lastFlushAt = time
    }

    /// Stop consuming fixes without ending the session. The buffer is committed
    /// first: a pause is exactly when someone puts the phone away.
    public func pause() throws {
        guard state == .recording else { return }
        try flush()
        state = .paused
    }

    public func resumeRecording() {
        guard state == .paused else { return }
        state = .recording
        // The gap says nothing about where they are now — a pause can be a
        // lunch stop or a night in a refuge. Let the next fix re-establish it
        // rather than scoring against a position hours old.
        matcher.reset()
        monitor.reset()
    }

    /// Finish and fold the journal into the package that leaves this device.
    public func finish(at time: Date = Date()) throws -> ActivityPackage {
        try flush(at: time)
        state = .finished
        return try journal.makePackage(
            status: recoveredFromCrash ? .recovered : .finished,
            endedAt: time,
            maxAccuracyM: configuration.matcher.maxAccuracyM,
            recoveredFromCrash: recoveredFromCrash
        )
    }

    /// Discard the session and its journal — an accidental start, or a walk the
    /// user does not want kept.
    public func discard() throws {
        buffer.removeAll()
        state = .finished
        try journal.delete()
    }
}
