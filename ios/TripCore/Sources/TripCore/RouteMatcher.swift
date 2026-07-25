import Foundation

/// Decides where on the route a fix puts the walker.
///
/// The naive version — snap to the nearest edge — fails in the places that
/// matter most. On a switchback the leg above is often closer than the leg
/// you are on; on the Tour du Mont Blanc the route passes near itself in
/// several valleys; on an out-and-back the two directions are the same line.
/// In all of those the wrong branch is *spatially* just as good, so distance
/// alone cannot separate them and a window around the last position only hides
/// the problem until the moment it matters.
///
/// So this is stateful: candidates are scored on how far they are from the fix
/// **and** on whether getting there from the last known position is physically
/// possible in the elapsed time. A jump backwards, or 400 m of progress in
/// twelve seconds, is rejected not because it is far but because nobody walks
/// like that.
public struct RouteMatcher: Sendable {
    public struct Configuration: Sendable {
        /// How far off the line a fix can be and still be considered on it.
        public var searchRadiusM: Double
        /// Fastest believable ground speed; anything implying more is a jump.
        public var maxSpeedMPS: Double
        /// Progress is scored against this pace, not penalised outright — a
        /// pause or a scramble should not cost a candidate its position.
        public var nominalSpeedMPS: Double
        /// Fixes worse than this never move the cursor.
        public var maxAccuracyM: Double
        /// How far along the route a rival candidate must sit before it counts
        /// as a genuine loop ambiguity rather than a neighbouring edge.
        public var ambiguitySeparationM: Double

        public init(
            searchRadiusM: Double = 300,
            maxSpeedMPS: Double = 4.0,
            nominalSpeedMPS: Double = 1.2,
            maxAccuracyM: Double = 50,
            ambiguitySeparationM: Double = 500
        ) {
            self.searchRadiusM = searchRadiusM
            self.maxSpeedMPS = maxSpeedMPS
            self.nominalSpeedMPS = nominalSpeedMPS
            self.maxAccuracyM = maxAccuracyM
            self.ambiguitySeparationM = ambiguitySeparationM
        }
    }

    public enum Confidence: String, Sendable, Equatable {
        /// Consistent with the previous position and the time since.
        case tracking
        /// Plausible but with a rival candidate far away on the route.
        case ambiguous
        /// The position moved faster than anyone walks.
        ///
        /// Reported rather than refused, because it is genuinely ambiguous: it
        /// is usually a GPS glitch, but the Tour du Mont Blanc has a cable car
        /// at Les Houches and the itinerary format has shuttle days, so a real
        /// leap does happen. The matcher follows the fix — GPS is the only
        /// ground truth available — and marks it so nothing downstream raises
        /// an alert on the strength of it.
        case jumped
        /// Nothing near enough, or the fix was too poor to use.
        case lost
    }

    public struct Match: Sendable, Equatable {
        public let routeDistanceM: Double
        public let offsetM: Double
        public let lat: Double
        public let lng: Double
        public let ele: Double?
        public let confidence: Confidence
        /// Metres of route progressed since the previous accepted fix.
        /// Negative means moving back along the route.
        public let progressM: Double
    }

    public let index: RouteIndex
    public var configuration: Configuration

    /// Last accepted position, and when. Nil means the matcher has no history
    /// to reason from and will fall back to an exhaustive search.
    private var lastRouteM: Double?
    private var lastTime: Date?

    public init(index: RouteIndex, configuration: Configuration = .init()) {
        self.index = index
        self.configuration = configuration
    }

    public var currentRouteDistanceM: Double? { lastRouteM }

    /// Forget the history — used when resuming a session on a different day,
    /// where the last position says nothing about where the walker is now.
    public mutating func reset() {
        lastRouteM = nil
        lastTime = nil
    }

    /// Seed the matcher with a known position, e.g. the start of a chosen stage.
    public mutating func seed(routeDistanceM: Double, at time: Date) {
        lastRouteM = routeDistanceM
        lastTime = time
    }

    // MARK: - Matching

    public mutating func match(_ fix: ActivityPackage.Fix) -> Match {
        // A fix the OS itself distrusts must never move the cursor: acting on
        // it produces phantom progress and false off-route alerts, the two
        // failure modes that cost the most trust on a real walk.
        guard fix.isUsable(maxAccuracyM: configuration.maxAccuracyM) else {
            return lostMatch(lat: fix.lat, lng: fix.lng)
        }

        // The search radius grows with the fix's own uncertainty; under tree
        // cover a 40 m fix genuinely may sit 40 m off the line.
        let radius = configuration.searchRadiusM + max(0, fix.hAcc)
        var candidates = index.candidates(lat: fix.lat, lng: fix.lng, radiusM: radius)

        if candidates.isEmpty {
            // Nothing nearby in the grid. One exhaustive scan tells us whether
            // this is genuinely off-route or the index simply had no cell here.
            guard let nearest = index.nearestExhaustive(lat: fix.lat, lng: fix.lng) else {
                return lostMatch(lat: fix.lat, lng: fix.lng)
            }
            candidates = [nearest]
        }

        let elapsed = max(lastTime.map { fix.t.timeIntervalSince($0) } ?? 0, 0)

        // Split first, score second. An earlier version scored every candidate
        // on a penalty proportional to how unreachable it was, which produced a
        // smooth gradient — and on a jump the winner became a point partway
        // between the old position and the new fix: somewhere the walker had
        // certainly never been. Either a candidate is reachable in the elapsed
        // time or it is not; there is no meaningful "slightly too far".
        let reachable: [RouteIndex.Projection]
        if let lastRouteM, elapsed > 0 {
            let limit = elapsed * configuration.maxSpeedMPS
            reachable = candidates.filter { abs($0.routeDistanceM - lastRouteM) <= limit }
        } else {
            reachable = candidates
        }

        // With nothing reachable, trust the fix: GPS is the only ground truth
        // available, and the result is flagged `.jumped` below.
        let pool = reachable.isEmpty ? candidates : reachable
        let scored = pool
            .map { (candidate: $0, score: score($0, elapsed: elapsed, amongReachable: !reachable.isEmpty)) }
            .sorted { $0.score < $1.score }

        guard let best = scored.first else { return lostMatch(lat: fix.lat, lng: fix.lng) }

        // Ambiguity means a rival that is *far along the route* yet nearly as
        // good — the loop-self-approach case. Neighbouring edges of the same
        // stretch are always metres apart and must not count.
        let rival = scored.dropFirst().first { candidate in
            abs(candidate.candidate.routeDistanceM - best.candidate.routeDistanceM)
                > configuration.ambiguitySeparationM
        }
        let ambiguous = rival.map { $0.score <= best.score * 1.5 } ?? false

        let progress = lastRouteM.map { best.candidate.routeDistanceM - $0 } ?? 0

        // A leap no walker could make. Every candidate near the new fix is
        // equally implausible, so there is nothing better to choose — follow it,
        // but say so.
        let elapsedOrZero = max(elapsed, 0)
        let jumped = lastRouteM != nil
            && elapsedOrZero > 0
            && abs(progress) > elapsedOrZero * configuration.maxSpeedMPS

        lastRouteM = best.candidate.routeDistanceM
        lastTime = fix.t

        let confidence: Confidence = jumped ? .jumped : (ambiguous ? .ambiguous : .tracking)
        return Match(
            routeDistanceM: best.candidate.routeDistanceM,
            offsetM: best.candidate.offsetM,
            lat: best.candidate.lat,
            lng: best.candidate.lng,
            ele: best.candidate.ele,
            confidence: confidence,
            progressM: progress
        )
    }

    /// Lower is better. Spatial distance is the base; the progress prior is
    /// what separates the right branch from a rival that happens to be equally
    /// close on a switchback or an out-and-back.
    ///
    /// When nothing was reachable the prior is dropped entirely and the nearest
    /// candidate wins — mixing a progress prior into a jump is what created the
    /// fictional in-between position this split exists to prevent.
    private func score(
        _ candidate: RouteIndex.Projection,
        elapsed: TimeInterval,
        amongReachable: Bool
    ) -> Double {
        guard amongReachable, let lastRouteM, elapsed > 0 else { return candidate.offsetM }

        var score = candidate.offsetM
        let delta = candidate.routeDistanceM - lastRouteM

        // Mild preference for forward progress at a walking pace. Deliberately
        // gentle — a rest stop, a wrong turn, or a scramble are all normal, and
        // a strong prior here would drag the cursor along when it should sit
        // still.
        let expected = elapsed * configuration.nominalSpeedMPS
        score += abs(delta - expected) * 0.05

        // Small extra cost for going backwards, which is rarer than pausing.
        if delta < 0 { score += abs(delta) * 0.05 }

        return score
    }

    private func lostMatch(lat: Double, lng: Double) -> Match {
        Match(
            routeDistanceM: lastRouteM ?? 0,
            offsetM: .infinity,
            lat: lat,
            lng: lng,
            ele: nil,
            confidence: .lost,
            progressM: 0
        )
    }
}
