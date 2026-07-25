import Foundation

/// Decides when to tell the walker they have left the route.
///
/// The threshold in the original plan — 200 m sustained over three fixes — is
/// wrong in both directions. At walking pace 200 m is roughly three minutes of
/// going the wrong way before anything is said, and at a 50 m distance filter
/// "three fixes" can be another 150 m on top. Meanwhile under tree cover a
/// stationary phone drifts far enough to trip a bare threshold repeatedly, and
/// an alert that cries wolf is worse than none: it gets ignored, then disabled.
///
/// So the decision is made on uncertainty, not on a raw number:
///
///   * enter only when `offset − accuracy` clears the threshold, i.e. when the
///     walker is off-route even granting the fix its own error bar;
///   * leave only when `offset + accuracy` is back under a lower threshold;
///   * between the two, hold whatever state is current — that gap is what stops
///     the flapping at the boundary;
///   * require the condition to persist over both time and distance, so one bad
///     fix cannot raise an alert on its own;
///   * and never fall silent: with no usable fixes the state becomes explicit
///     rather than looking like "still on route".
public struct OffRouteMonitor: Sendable {
    public struct Configuration: Sendable {
        /// Off-route once `offset − accuracy` exceeds this.
        public var enterM: Double
        /// Back on route once `offset + accuracy` drops below this.
        public var exitM: Double
        /// The condition must hold at least this long before alerting.
        public var sustainedFor: TimeInterval
        /// …and over at least this much travel, so standing still while a fix
        /// wanders cannot satisfy the time condition on its own.
        public var sustainedOverM: Double
        /// No usable fix for this long means the GPS state is reported, not
        /// silently assumed to be unchanged.
        public var noFixAfter: TimeInterval

        public init(
            enterM: Double = 75,
            exitM: Double = 40,
            sustainedFor: TimeInterval = 30,
            sustainedOverM: Double = 30,
            noFixAfter: TimeInterval = 120
        ) {
            self.enterM = enterM
            self.exitM = exitM
            self.sustainedFor = sustainedFor
            self.sustainedOverM = sustainedOverM
            self.noFixAfter = noFixAfter
        }

        /// Thresholds published with the trip; the planner picks them per route
        /// because a broad waymarked path and a faint traverse do not deserve
        /// the same sensitivity.
        public init(navigationDefaults: TripPackage.NavigationDefaults) {
            self.init(
                enterM: Double(navigationDefaults.offRouteEnterM),
                exitM: Double(navigationDefaults.offRouteExitM)
            )
        }
    }

    public enum State: String, Sendable, Equatable {
        /// No position yet.
        case acquiring
        case onRoute
        /// Past the threshold, but not yet for long enough to be believed.
        case suspect
        case offRoute
        /// Fixes arriving but too poor to judge with.
        case degraded
        /// Nothing usable for a while — reported, never mistaken for on-route.
        case noFix
    }

    public struct Update: Sendable, Equatable {
        public let state: State
        /// True on the transition into `offRoute` — the moment to alert, and
        /// only once, so a notification does not repeat every fix.
        public let didEnterOffRoute: Bool
        /// True on the transition back to `onRoute` from `offRoute`.
        public let didReturnToRoute: Bool
    }

    public var configuration: Configuration
    private(set) public var state: State = .acquiring

    /// When and where the current suspicion began, for the sustain test.
    private var suspectSince: Date?
    private var suspectAtRouteM: Double?
    private var lastUsableFixAt: Date?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        state = .acquiring
        suspectSince = nil
        suspectAtRouteM = nil
        lastUsableFixAt = nil
    }

    /// Feed one matched fix. `accuracyM` is the fix's own horizontal accuracy.
    public mutating func update(match: RouteMatcher.Match, accuracyM: Double, at time: Date) -> Update {
        let previous = state

        // An unusable fix must not be read as "still fine". If they keep coming
        // the state degrades, and after long enough it becomes an explicit
        // no-fix that the UI is obliged to show.
        guard match.confidence != .lost else {
            let silentFor = lastUsableFixAt.map { time.timeIntervalSince($0) } ?? .infinity
            state = silentFor >= configuration.noFixAfter ? .noFix : .degraded
            return Update(state: state, didEnterOffRoute: false, didReturnToRoute: false)
        }

        // A jump is not evidence of anything yet: a GPS glitch and a cable car
        // look identical for one fix. Clear any suspicion built up before it —
        // the pre-jump deviation says nothing about where the walker is now —
        // and wait for the next fix to establish a position worth judging.
        if match.confidence == .jumped {
            lastUsableFixAt = time
            suspectSince = nil
            suspectAtRouteM = nil
            if state == .offRoute { state = .suspect }
            return Update(state: state, didEnterOffRoute: false, didReturnToRoute: false)
        }

        lastUsableFixAt = time
        let accuracy = max(0, accuracyM)
        // Granting the fix its error bar in both directions is what keeps a
        // noisy position from being called off-route, and a confident one from
        // being excused.
        let certainlyOff = match.offsetM - accuracy
        let possiblyOn = match.offsetM + accuracy

        if certainlyOff > configuration.enterM {
            if suspectSince == nil {
                suspectSince = time
                suspectAtRouteM = match.routeDistanceM
                if state != .offRoute { state = .suspect }
            }
            let heldFor = time.timeIntervalSince(suspectSince ?? time)
            let movedM = abs(match.routeDistanceM - (suspectAtRouteM ?? match.routeDistanceM))
            // Time *and* distance: a phone on a rock can satisfy the clock
            // while its fix wanders, and that is not a wrong turn.
            if state != .offRoute, heldFor >= configuration.sustainedFor, movedM >= configuration.sustainedOverM {
                state = .offRoute
                return Update(state: state, didEnterOffRoute: true, didReturnToRoute: false)
            }
        } else if possiblyOn < configuration.exitM {
            suspectSince = nil
            suspectAtRouteM = nil
            let returned = previous == .offRoute
            state = .onRoute
            return Update(state: state, didEnterOffRoute: false, didReturnToRoute: returned)
        } else {
            // The band between exit and enter: deliberately no decision. This
            // is the hysteresis that stops an alert flapping on and off while
            // someone walks along the edge of the threshold.
            if state == .acquiring || state == .degraded || state == .noFix { state = .onRoute }
        }

        return Update(state: state, didEnterOffRoute: false, didReturnToRoute: false)
    }
}
