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
        /// How far the walker has actually walked, summed from the fixes.
        ///
        /// Not the same as `routeDistanceM`, and the difference is the whole
        /// point: cut a corner and rejoin near the finish and the projection
        /// sits near the finish, so progress along the line reads almost
        /// complete while the legs know otherwise.
        public let walkedM: Double
        /// Position snapped onto the route.
        ///
        /// What the route-derived numbers are measured from. It is *not* what
        /// the map should draw — see `fixLat`.
        public let lat: Double
        public let lng: Double
        /// Where the receiver actually says the walker is.
        ///
        /// The map draws this. It used to draw the snapped position, on the
        /// reasoning that a marker jittering beside the line reads as a bug
        /// rather than as noise. That holds for the five metres a good fix
        /// wanders; it is a lie at seventeen and a serious one at two hundred,
        /// and a map that draws somebody where they are not is the exact
        /// failure the accuracy priority forbids.
        public let fixLat: Double
        public let fixLng: Double
        /// The direction the walker is moving, when the receiver knows it.
        ///
        /// Nil while stationary or before the receiver has settled, in which
        /// case the arrow falls back to the direction the route runs.
        public let courseDegrees: Double?
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
    private var powerBuffer: [Power.Sample] = []
    private var walkedM: Double = 0
    private var lastUsableFix: ActivityPackage.Fix?
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
        if fix.isUsable(maxAccuracyM: configuration.matcher.maxAccuracyM) {
            // Accumulated as the walk happens, by the same rule the finished
            // activity is summed with, so the number on the screen and the
            // number in the saved walk cannot disagree.
            if let last = lastUsableFix {
                walkedM += WalkedDistance.step(from: last, to: fix)
            }
            lastUsableFix = fix
        } else {
            rejectedFixes += 1
        }

        if buffer.count >= configuration.flushEveryFixes
            || time.timeIntervalSince(lastFlushAt) >= configuration.flushInterval {
            try flush(at: time)
        }

        // The receiver reports a course only once it is confident of the
        // direction, and reports it as negative when it is not. Standing still
        // it is meaningless whatever the sign says, so the same speed threshold
        // that keeps the distance honest decides whether the arrow may use it.
        let moving = (speed ?? 0) >= WalkedDistance.stationarySpeedMPS
            && (bearing ?? -1) >= 0

        let match = matcher.match(fix)
        let update = monitor.update(match: match, accuracyM: horizontalAccuracyM, at: time)

        let next = package.checkpoints.first { Double($0.routeDistanceM) > match.routeDistanceM }
        let progress = Progress(
            routeDistanceM: match.routeDistanceM,
            remainingM: max(0, index.totalM - match.routeDistanceM),
            offsetM: match.offsetM,
            walkedM: walkedM,
            lat: match.lat,
            lng: match.lng,
            fixLat: fix.lat,
            fixLng: fix.lng,
            courseDegrees: moving ? bearing : nil,
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

    /// Record a battery reading.
    ///
    /// Buffered like a fix and written on the same flush, so a nine-day
    /// measurement costs no wakeups of its own. The caller decides how often to
    /// offer one; this only decides when it reaches the disk.
    public func receive(power sample: Power.Sample) {
        powerBuffer.append(sample)
    }

    /// Commit whatever is buffered. Called on the flush schedule, and by the
    /// app whenever it is about to lose control — backgrounding, termination
    /// warnings, low power.
    public func flush(at time: Date = Date()) throws {
        if !powerBuffer.isEmpty {
            try journal.appendPower(contentsOf: powerBuffer)
            powerBuffer.removeAll(keepingCapacity: true)
        }
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

        // The off-route judgement starts again — a deviation from before lunch
        // says nothing about now, and replaying it would alert about something
        // hours old.
        monitor.reset()

        // The *position* is kept. This used to be reset too, on the reasoning
        // that a pause can be a lunch stop or a night in a refuge, so the old
        // position was stale. But stale is not the same as worthless: a walker
        // resuming is somewhere a walker could have got to, and the matcher
        // already widens its window by the elapsed time — an hour allows 14 km,
        // a night allows more than the whole route, so a long pause relaxes
        // into the old behaviour by itself.
        //
        // What the reset cost is the one case that needs it most. Stand on the
        // start line of a loop and two candidates 164 km apart are metres
        // apart on the ground; with no prior the winner is decided by the order
        // the candidates happen to come out of the index. Having been at metre
        // 300 a moment ago settles it on evidence instead.
    }

    /// Finish and fold the journal into the package that leaves this device.
    public func finish(at time: Date = Date()) throws -> ActivityPackage {
        try flush(at: time)
        state = .finished
        let package = try journal.makePackage(
            status: recoveredFromCrash ? .recovered : .finished,
            endedAt: time,
            maxAccuracyM: configuration.matcher.maxAccuracyM,
            recoveredFromCrash: recoveredFromCrash
        )
        // Committed here, not left to the caller. Handing the package back and
        // trusting the screen to keep it is how a finished walk used to end up
        // existing only in memory.
        try journal.commit(package)
        return package
    }

    /// Discard the session and its journal — an accidental start, or a walk the
    /// user does not want kept.
    public func discard() throws {
        buffer.removeAll()
        state = .finished
        try journal.delete()
    }
}
