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
        /// Above this deviation the travel condition is waived.
        ///
        /// The travel requirement exists to ignore a phone resting on a rock
        /// while its fix wanders — drift measured in tens of metres. A walker
        /// several hundred metres off the line who has stopped is not drifting,
        /// they are lost and standing still, which is precisely when the alert
        /// is worth most. Defaults to three times `enterM`.
        public var alertRegardlessOfTravelM: Double
        /// No usable fix for this long means the GPS state is reported, not
        /// silently assumed to be unchanged.
        public var noFixAfter: TimeInterval

        public init(
            enterM: Double = 75,
            exitM: Double = 40,
            sustainedFor: TimeInterval = 30,
            sustainedOverM: Double = 30,
            noFixAfter: TimeInterval = 120,
            alertRegardlessOfTravelM: Double? = nil
        ) {
            self.enterM = enterM
            self.exitM = exitM
            self.sustainedFor = sustainedFor
            self.sustainedOverM = sustainedOverM
            self.noFixAfter = noFixAfter
            self.alertRegardlessOfTravelM = alertRegardlessOfTravelM ?? enterM * 3
        }

        /// Thresholds published with the trip; the planner picks them per route
        /// because a broad waymarked path and a faint traverse do not deserve
        /// the same sensitivity.
        ///
        /// Validated, not trusted: an exit at or above the enter threshold would
        /// erase the hysteresis and make the alert flap, and a non-positive
        /// threshold is meaningless. Any of those and the trip's values are
        /// dropped for the defaults — a malformed package must not be able to
        /// break the one alert that matters on a mountain.
        public init(navigationDefaults: TripPackage.NavigationDefaults) {
            let enter = Double(navigationDefaults.offRouteEnterM)
            let exit = Double(navigationDefaults.offRouteExitM)
            let usable = enter > 0 && exit > 0 && exit < enter
            let defaults = Configuration()
            self.init(
                enterM: usable ? enter : defaults.enterM,
                exitM: usable ? exit : defaults.exitM
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
        /// True on the transition into `noFix` — the moment to say the GPS is
        /// lost, once, whether that transition came from a fix too poor to use
        /// or from `evaluate` finding no fix has arrived in too long.
        public let didEnterNoFix: Bool

        init(
            state: State,
            didEnterOffRoute: Bool = false,
            didReturnToRoute: Bool = false,
            didEnterNoFix: Bool = false
        ) {
            self.state = state
            self.didEnterOffRoute = didEnterOffRoute
            self.didReturnToRoute = didReturnToRoute
            self.didEnterNoFix = didEnterNoFix
        }
    }

    public var configuration: Configuration
    private(set) public var state: State = .acquiring

    /// When and where the current suspicion began, for the sustain test.
    private var suspectSince: Date?
    private var suspectAtRouteM: Double?
    private var lastUsableFixAt: Date?
    /// The first time the monitor saw anything at all. Before a single usable
    /// fix has arrived there is no `lastUsableFixAt` to measure silence from,
    /// and the honest baseline is when recording began — otherwise the very
    /// first fix, if poor, reads as infinitely-long silence and jumps straight
    /// to `noFix` instead of `acquiring`.
    private var firstSeenAt: Date?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        state = .acquiring
        suspectSince = nil
        suspectAtRouteM = nil
        lastUsableFixAt = nil
        firstSeenAt = nil
    }

    /// Time has passed with no new fix at all. Core Location can simply stop
    /// delivering — in a gorge, under dense cover — and when it does, `update`
    /// is never called and the last state would otherwise stand forever, saying
    /// "on route" about a position minutes stale. Driven by a timer while the
    /// app is foreground; in the background the process is suspended and nothing
    /// can run until a fix or the user wakes it, at which point this or `update`
    /// catches up.
    public mutating func evaluate(at time: Date) -> Update {
        if firstSeenAt == nil { firstSeenAt = time }
        let previous = state
        let baseline = lastUsableFixAt ?? firstSeenAt ?? time
        let silentFor = time.timeIntervalSince(baseline)

        guard silentFor >= configuration.noFixAfter else {
            return Update(state: state)
        }
        state = .noFix
        return Update(state: state, didEnterNoFix: previous != .noFix)
    }

    /// Feed one matched fix. `accuracyM` is the fix's own horizontal accuracy.
    public mutating func update(match: RouteMatcher.Match, accuracyM: Double, at time: Date) -> Update {
        if firstSeenAt == nil { firstSeenAt = time }
        let previous = state

        // An unusable fix must not be read as "still fine". If they keep coming
        // the state degrades, and after long enough it becomes an explicit
        // no-fix that the UI is obliged to show. Before any usable fix has ever
        // arrived there is nothing to have gone stale, so silence is measured
        // from when recording began and the honest state is `acquiring`, not a
        // `noFix` conjured from a nil timestamp read as infinite.
        guard match.confidence != .lost else {
            let baseline = lastUsableFixAt ?? firstSeenAt ?? time
            let silentFor = time.timeIntervalSince(baseline)
            let hadAFix = lastUsableFixAt != nil
            if silentFor >= configuration.noFixAfter {
                state = .noFix
                return Update(state: state, didEnterNoFix: previous != .noFix)
            }
            state = hadAFix ? .degraded : .acquiring
            return Update(state: state)
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
            // Time, plus either travel or a deviation too large to be drift.
            // Travel alone was the original rule and it left someone parked
            // 400 m off the line permanently on "possibly off route" — the
            // exact moment the alert matters, since stopping to check the map
            // is what people do once they suspect they are lost.
            let confirmed = movedM >= configuration.sustainedOverM
                || certainlyOff >= configuration.alertRegardlessOfTravelM
            if state != .offRoute, heldFor >= configuration.sustainedFor, confirmed {
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
            //
            // Note that `suspectSince` is *not* cleared here, only when the
            // walker gets properly back on route below `exitM`. So someone who
            // hovers around the threshold for several minutes and then clearly
            // exceeds it will alert immediately rather than restarting the
            // sustain timer. That is intended: prolonged marginal wandering is
            // itself evidence of a wrong turn, and only a confident return to
            // the line should wipe the slate.
            if state == .acquiring || state == .degraded || state == .noFix { state = .onRoute }
        }

        return Update(state: state, didEnterOffRoute: false, didReturnToRoute: false)
    }
}
