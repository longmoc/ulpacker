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
        /// Floor for the ambiguity margin, used when a fix reports implausibly
        /// good accuracy. Two branches this close are indistinguishable in
        /// practice whatever the device claims.
        public var minimumAmbiguityMarginM: Double
        /// How much longer a path may be than the straight line between two
        /// fixes. Switchbacks are why this is not 1; it is still far below
        /// what a jump to the far side of a loop would require.
        public var windingAllowance: Double
        /// Beyond this far from the line, the nearest point on the route stops
        /// being a position and becomes an artefact.
        ///
        /// Every fix has a nearest point on the route — a fix in another
        /// country has one. Without a limit the matcher answers the question it
        /// was asked, faithfully and uselessly: start the app anywhere but the
        /// Alps and it reports a confident position 28 km along the Tour du
        /// Mont Blanc, because that is genuinely the closest the route comes.
        ///
        /// Two kilometres is chosen to be well beyond any real detour — a wrong
        /// turn, a variant, a bail-out down a valley are all far inside it —
        /// while excluding the case where the walker is not on this walk at all.
        public var maxCredibleOffsetM: Double
        /// Ends closer than this make the route a closed loop.
        public var closureGapM: Double

        public init(
            searchRadiusM: Double = 300,
            maxSpeedMPS: Double = 4.0,
            nominalSpeedMPS: Double = 1.2,
            maxAccuracyM: Double = 50,
            ambiguitySeparationM: Double = 500,
            minimumAmbiguityMarginM: Double = 10,
            windingAllowance: Double = 4,
            maxCredibleOffsetM: Double = 2_000,
            closureGapM: Double = 150
        ) {
            self.searchRadiusM = searchRadiusM
            self.maxSpeedMPS = maxSpeedMPS
            self.nominalSpeedMPS = nominalSpeedMPS
            self.maxAccuracyM = maxAccuracyM
            self.ambiguitySeparationM = ambiguitySeparationM
            self.minimumAmbiguityMarginM = minimumAmbiguityMarginM
            self.windingAllowance = windingAllowance
            self.maxCredibleOffsetM = maxCredibleOffsetM
            self.closureGapM = closureGapM
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
        /// The fix itself was too poor to use. Says nothing about where the
        /// walker is relative to the route — only that this reading cannot
        /// tell. Freshness is not refreshed by it: a run of these is what a
        /// failing signal looks like.
        case lost
        /// A good fix, but nowhere credibly near this route — beyond
        /// `maxCredibleOffsetM`. The receiver is fine; the walker is simply not
        /// on this walk yet (a hotel, a car park, a bus).
        ///
        /// Kept apart from `.lost` because the two were once the same case and
        /// the app treated both as "no signal": a walker two kilometres from
        /// the trailhead with a 5 m fix got a "No GPS fix" notification, and a
        /// single 70 m fix under trees turned the screen red with "Not on this
        /// route". One is a statement about the receiver, the other about the
        /// walker's position; they need different words and different alarms.
        case distant
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
    /// The last accepted fix's own coordinates, needed to tell a real move
    /// from a jump to another part of the route.
    private var lastLat: Double?
    private var lastLng: Double?
    /// The furthest point on the route the walker has actually been at — a
    /// tracking match within `highWaterOffsetM` of the line. What tells the
    /// start of a closed loop from its finish, which are the same ground.
    private var highWaterM: Double?

    /// Present when the route closes on itself: the first and last points are
    /// the same place, so route metre 0 and route metre `totalM` are too.
    ///
    /// Both real loops in use are closed this way — the Tour du Mont Blanc
    /// (0 m between its ends) and the test loop near home (10 m) — and neither
    /// sets the package's `loop` flag, so this is detected from geometry.
    private struct Closure: Sendable {
        let totalM: Double
        /// Candidates this close to either end, along the route, belong to it.
        let zoneM: Double
    }
    private let closure: Closure?

    public init(index: RouteIndex, configuration: Configuration = .init()) {
        self.index = index
        self.configuration = configuration
        if let first = index.edges.first, let last = index.edges.last,
           ActivityJournal.haversine(first.startLat, first.startLng, last.endLat, last.endLng)
               <= configuration.closureGapM {
            closure = Closure(totalM: index.totalM, zoneM: min(2_000, index.totalM / 4))
        } else {
            closure = nil
        }
    }

    /// A tracking match this close to the line counts as having been there.
    private static let highWaterOffsetM = 100.0

    public var currentRouteDistanceM: Double? { lastRouteM }

    /// Forget the history — used when resuming a session on a different day,
    /// where the last position says nothing about where the walker is now.
    public mutating func reset() {
        lastRouteM = nil
        lastTime = nil
        lastLat = nil
        lastLng = nil
        highWaterM = nil
    }

    /// Seed the matcher with a known position, e.g. the start of a chosen stage
    /// or the cursor recovered after a crash.
    ///
    /// Pass where the walker physically was when there is a fix for it. The
    /// progress prior measures how far the walker has *moved* since then, and
    /// without a location it cannot — which is how a recovered session used to
    /// fall back to assuming the walker kept walking for the whole outage.
    public mutating func seed(routeDistanceM: Double, at time: Date, lat: Double? = nil, lng: Double? = nil) {
        lastRouteM = routeDistanceM
        lastTime = time
        if let lat, let lng { lastLat = lat; lastLng = lng }
        highWaterM = max(highWaterM ?? 0, routeDistanceM)
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
            let nearest = index.nearestExhaustive(lat: fix.lat, lng: fix.lng)
            guard let nearest, nearest.offsetM <= configuration.maxCredibleOffsetM else {
                // The fix passed the accuracy gate above, so this is a good
                // position that simply has no credible point on the route.
                return distantMatch(fix: fix, offsetM: nearest?.offsetM ?? .infinity)
            }
            candidates = [nearest]
        }

        let elapsed = max(lastTime.map { fix.t.timeIntervalSince($0) } ?? 0, 0)

        // The fastest the walker could have gone. Normally the walking ceiling,
        // but when the receiver itself measures more — a cable car, a shuttle,
        // the motorbike ride on the 12 October test — believe it. With a fixed
        // 4 m/s the cursor fell behind a 6–7 m/s ride, the offset climbed to
        // 40–54 m, and the escape hatch caught up with a "Position jumped"
        // banner four times in fifty seconds. Doppler speed is the receiver's
        // most reliable output, and a margin keeps a burst from being clipped.
        let speedCeiling = max(configuration.maxSpeedMPS, (fix.speed ?? 0) * 1.5)

        // Split first, score second. An earlier version scored every candidate
        // on a penalty proportional to how unreachable it was, which produced a
        // smooth gradient — and on a jump the winner became a point partway
        // between the old position and the new fix: somewhere the walker had
        // certainly never been. Either a candidate is reachable in the elapsed
        // time or it is not; there is no meaningful "slightly too far".
        let reachable: [RouteIndex.Projection]
        if let lastRouteM, elapsed > 0 {
            let limit = elapsed * speedCeiling
            reachable = candidates.filter { abs($0.routeDistanceM - lastRouteM) <= limit }
        } else {
            reachable = candidates
        }

        // With nothing reachable, fall back — but not all the way to "nearest
        // wins". Candidates whose route jump the walker could not physically
        // have covered are dropped first, and only if that leaves nothing does
        // the raw fix win outright.
        //
        // Skipping this step is what let a walker at Les Houches be placed
        // 163 km along the loop: the route closes on itself there, and stepping
        // 400 m off the line makes the finish leg genuinely the nearest one.
        var pool = reachable
        var escaped = false
        if pool.isEmpty {
            var explainable = candidates.filter { isPhysicallyExplainable($0, from: fix) }

            // Nothing the walker could have reached is in view. Usually that is
            // because they are further off the line than the search radius —
            // the branch they are actually on is simply out of range, while
            // some other part of the route is not. Widen and look again rather
            // than accept the only thing visible: at Les Houches, where the
            // loop closes, the only visible candidate is the finish leg, and
            // taking it credits 163 km to someone who walked 400 m.
            if explainable.isEmpty {
                let wider = index.candidates(lat: fix.lat, lng: fix.lng, radiusM: radius * 4)
                explainable = wider.filter { isPhysicallyExplainable($0, from: fix) }
                if !explainable.isEmpty { candidates = wider }
            }

            // Still nothing: a genuine teleport — a glitch, a lift, a shuttle.
            // Follow the fix and let `.jumped` say so.
            pool = explainable.isEmpty ? candidates : explainable
        }

        // The reachable filter needs an escape hatch, or it becomes a trap.
        // Found by replaying a real recording: when the walker outruns
        // `maxSpeedMPS` — a glitch, a cable car, a burst downhill, or fixes
        // resuming after the app was starved — the nearest reachable candidate
        // creeps forward at the speed limit while the true position pulls away.
        // The matcher then reported `.tracking` with the offset climbing past
        // 190 m, which is a false off-route alert raised at the exact moment
        // the walker is precisely on the path.
        //
        // So: if abandoning the model puts us dramatically closer to what the
        // receiver actually reports, believe the receiver. The margin is wide
        // enough that ordinary noise never triggers it, which keeps the
        // progress prior doing its job on switchbacks and parallel paths.
        //
        // The comparison is against the best candidate the walker could
        // physically have reached, not against the nearest one outright. It
        // used to require the nearest to be explainable, which made the result
        // depend on which of two equally good answers happened to be a few
        // metres closer: rejoining a closed loop at its seam, where the start
        // and finish legs are both metres away, escaped when the start leg was
        // nearer and stayed trapped on a stale branch — offset climbing, a
        // false off-route — when the finish leg was. The pool is then only the
        // explainable candidates, so the winner is always one of them.
        let explainable = candidates.filter { isPhysicallyExplainable($0, from: fix) }
        if !reachable.isEmpty,
           let bestReachable = reachable.min(by: { $0.offsetM < $1.offsetM }),
           let bestExplainable = explainable.min(by: { $0.offsetM < $1.offsetM }),
           bestReachable.offsetM > bestExplainable.offsetM + escapeMargin(for: fix) {
            pool = explainable
            escaped = true
        }

        let displacement = lastLat.flatMap { la in
            lastLng.map { ActivityJournal.haversine(la, $0, fix.lat, fix.lng) }
        }
        let scored = pool
            .map {
                (candidate: $0, score: score($0, elapsed: elapsed, displacement: displacement,
                                             amongReachable: !reachable.isEmpty && !escaped))
            }
            .sorted { $0.score < $1.score }

        // The fix is usable by this point, so an empty result is a statement
        // about the route, not the receiver.
        guard var best = scored.first else { return distantMatch(fix: fix, offsetM: .infinity) }
        if let preferred = closurePreference(scored, fix: fix) { best = preferred }

        // Ambiguity means a rival that is *far along the route* yet nearly as
        // good — the loop-self-approach case. Neighbouring edges of the same
        // stretch are always metres apart and must not count.
        let rival = scored.first { candidate in
            abs(candidate.candidate.routeDistanceM - best.candidate.routeDistanceM)
                > configuration.ambiguitySeparationM
        }

        // The margin is additive and scaled by the fix's own uncertainty, not a
        // multiple of the best score. A multiplicative test gets this exactly
        // backwards: the better the fix, the smaller the best score, and the
        // harder ambiguity becomes to declare — at offset 0, standing precisely
        // on one leg of a hairpin, no rival could ever qualify. That is the one
        // case this check exists for. Two branches within a fix's error bar of
        // each other are indistinguishable however good the fix is.
        let margin = max(configuration.minimumAmbiguityMarginM, max(0, fix.hAcc))
        let ambiguous = rival.map { $0.score <= best.score + margin } ?? false

        let progress = lastRouteM.map { best.candidate.routeDistanceM - $0 } ?? 0

        // A leap no walker could make. Every candidate near the new fix is
        // equally implausible, so there is nothing better to choose — follow it,
        // but say so.
        let elapsedOrZero = max(elapsed, 0)
        let jumped = escaped
            || (lastRouteM != nil
                && elapsedOrZero > 0
                && abs(progress) > elapsedOrZero * speedCeiling)

        lastRouteM = best.candidate.routeDistanceM
        lastTime = fix.t
        lastLat = fix.lat
        lastLng = fix.lng

        let confidence: Confidence = jumped ? .jumped : (ambiguous ? .ambiguous : .tracking)
        if confidence == .tracking, best.candidate.offsetM <= Self.highWaterOffsetM {
            highWaterM = max(highWaterM ?? 0, best.candidate.routeDistanceM)
        }
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
        displacement: Double?,
        amongReachable: Bool
    ) -> Double {
        guard amongReachable, let lastRouteM, elapsed > 0 else { return candidate.offsetM }

        var score = candidate.offsetM
        let delta = candidate.routeDistanceM - lastRouteM

        // Mild preference for forward progress at a walking pace. Deliberately
        // gentle — a rest stop, a wrong turn, or a scramble are all normal, and
        // a strong prior here would drag the cursor along when it should sit
        // still.
        // Expected progress is what the walker could have covered *given how far
        // they actually moved*. Time alone is not evidence of walking: the
        // bare `elapsed × pace` assumed the walker kept going through every
        // stop, so a thirteen-minute pause "expected" a kilometre of progress
        // and — on a route that comes back near itself — pulled the cursor
        // 1.5 km onto another branch while the walker had moved 24 m. Found by
        // replaying a real walk. A 60-minute lunch expected 4.3 km.
        //
        // Bounded, not replaced: while walking, displacement × winding is well
        // above elapsed × pace, so ordinary tracking is unchanged.
        var expected = elapsed * configuration.nominalSpeedMPS
        if let displacement {
            expected = min(expected, displacement * configuration.windingAllowance)
        }
        score += abs(delta - expected) * 0.05

        // Small extra cost for going backwards, which is rarer than pausing.
        if delta < 0 { score += abs(delta) * 0.05 }

        return score
    }

    /// How much closer to the observation an unreachable candidate must be
    /// before the model is abandoned. Scaled by the fix's own error so a vague
    /// fix cannot argue its way out of the constraint on noise alone.
    private func escapeMargin(for fix: ActivityPackage.Fix) -> Double {
        max(50, 3 * max(0, fix.hAcc))
    }

    /// Whether a candidate's route jump is consistent with the ground the
    /// walker actually covered.
    ///
    /// This is what separates the two cases the escape hatch has to tell apart.
    /// A GPS glitch or a cable car moves the walker *physically* about as far
    /// as the route distance implies. A loop closing on itself does not: on the
    /// Tour du Mont Blanc, stepping 400 m off the line near Les Houches makes
    /// the finish leg genuinely nearer than the start leg, and following it
    /// would credit 163 km of progress to someone who moved 400 m.
    ///
    /// Route distance can exceed straight-line displacement — paths wind — so
    /// the allowance is generous. It is still nowhere near a whole loop.
    private func isPhysicallyExplainable(
        _ candidate: RouteIndex.Projection,
        from fix: ActivityPackage.Fix
    ) -> Bool {
        guard let lastRouteM, let lastLat, let lastLng else { return true }
        let displacement = ActivityJournal.haversine(lastLat, lastLng, fix.lat, fix.lng)
        let routeJump = abs(candidate.routeDistanceM - lastRouteM)
        return routeJump <= displacement * configuration.windingAllowance + escapeMargin(for: fix) * 4
    }

    /// On a closed loop, choose between the two ends when the fix fits both.
    ///
    /// Standing at the seam, "metre 0" and "metre `totalM`" are the same place
    /// and the geometry cannot choose. What can is how far round the walker has
    /// been: nowhere yet, and this is the start of the day; more than half way,
    /// and this is the finish. Before this the choice fell to whichever end the
    /// index returned first — which is how a walk on day one at Les Houches
    /// avoided reading "finished" by luck rather than by reason.
    ///
    /// Only intervenes when both ends are in play and fit the fix about equally
    /// well; if one end clearly fits better, that evidence stands.
    private func closurePreference(
        _ scored: [(candidate: RouteIndex.Projection, score: Double)],
        fix: ActivityPackage.Fix
    ) -> (candidate: RouteIndex.Projection, score: Double)? {
        guard let closure else { return nil }
        let startSide = scored.filter { $0.candidate.routeDistanceM < closure.zoneM }
        let finishSide = scored.filter { $0.candidate.routeDistanceM > closure.totalM - closure.zoneM }
        guard let bestStart = startSide.min(by: { $0.candidate.offsetM < $1.candidate.offsetM }),
              let bestFinish = finishSide.min(by: { $0.candidate.offsetM < $1.candidate.offsetM })
        else { return nil }

        let preferFinish = (highWaterM ?? 0) >= closure.totalM / 2
        let preferred = preferFinish ? bestFinish : bestStart
        let other = preferFinish ? bestStart : bestFinish
        let tolerance = max(configuration.minimumAmbiguityMarginM, max(0, fix.hAcc))
        return preferred.candidate.offsetM <= other.candidate.offsetM + tolerance ? preferred : nil
    }

    /// A good fix with no credible route point. Like `lostMatch` it leaves the
    /// cursor where it was — reporting the nearest point of a route five
    /// kilometres away would be the confident, useless answer — but it carries
    /// the real distance, so the readout can say how far off the walker is and
    /// the off-route judgement has a number to work with.
    private func distantMatch(fix: ActivityPackage.Fix, offsetM: Double) -> Match {
        Match(
            routeDistanceM: lastRouteM ?? 0,
            offsetM: offsetM,
            lat: fix.lat,
            lng: fix.lng,
            ele: nil,
            confidence: .distant,
            progressM: 0
        )
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
