import Foundation

/// What it takes to walk from one point on the route to another: how far, how
/// much climb, and how long.
///
/// This is the question the walker actually asks a map — "can I still make the
/// refuge, or do I stop here?" — and answering it needs all three numbers
/// together. Four kilometres is an hour along a valley and three hours over a
/// col, and the difference is entirely in the climb.
///
/// The ascent and descent figures mirror `buildTrackStats` and `statsForRange`
/// in `trail.js` exactly: a five-point moving average over each contiguous run
/// of elevations, then the positive and negative deltas summed separately. That
/// smoothing is not cosmetic. Raw GPX elevations wander by a metre or two
/// between neighbouring points, and summed unfiltered over eight thousand
/// points they invent hundreds of metres of climb that nobody walks. Matching
/// the planner's method matters just as much: a day that reads 1,530 m on the
/// web and 1,900 m on the phone would leave the walker with no idea which to
/// believe.
public struct RouteProfile: Sendable {
    /// One route point reduced to what the climb calculation needs.
    struct Sample: Sendable {
        let routeM: Double
        let ele: Double?
        let segmentIndex: Int
        let lat: Double
        let lng: Double
    }

    let samples: [Sample]
    public let totalM: Double

    public init(package: TripPackage) {
        var samples: [Sample] = []
        var routeM = 0.0
        var previous: TrackPoint?

        for (segmentIndex, segment) in package.plannedRoute.segments.enumerated() {
            // A segment break is a gap in the walk — a shuttle, a lift — so
            // distance does not accumulate across it and neither does climb.
            previous = nil
            for point in segment.points {
                if let previous {
                    routeM += ActivityJournal.haversine(
                        previous.lat, previous.lng, point.lat, point.lng
                    )
                }
                previous = point
                samples.append(
                    Sample(
                        routeM: routeM,
                        ele: point.ele.map(Double.init),
                        segmentIndex: segmentIndex,
                        lat: point.lat,
                        lng: point.lng
                    )
                )
            }
        }

        self.samples = samples
        self.totalM = routeM
    }

    // MARK: - Legs

    /// Distance, climb and time between two points on the route.
    public struct Leg: Sendable, Equatable {
        public let distanceM: Double
        /// Nil when the route carries no elevation over this stretch — which is
        /// different from zero, and the walker should be told so rather than
        /// shown a flat walk that isn't.
        public let ascentM: Double?
        public let descentM: Double?
        public let duration: TimeInterval?
        /// The target lies back the way the walker came. The climb figures are
        /// for walking it in that direction, so they are the reverse of the
        /// planned leg's.
        public let isBehind: Bool
    }

    /// The leg from one route position to another.
    ///
    /// Works in either direction. A stop already passed is a real question —
    /// the last water, the refuge you could turn back to — and going back down
    /// what you climbed is not the same walk as climbing it, so the ascent and
    /// descent swap rather than being reported as planned.
    public func leg(fromRouteM: Double, toRouteM: Double) -> Leg {
        let isBehind = toRouteM < fromRouteM
        let lower = min(fromRouteM, toRouteM)
        let upper = max(fromRouteM, toRouteM)
        let climb = climbBetween(lower, upper)

        let ascentM = isBehind ? climb.descent : climb.ascent
        let descentM = isBehind ? climb.ascent : climb.descent
        return Leg(
            distanceM: upper - lower,
            ascentM: ascentM,
            descentM: descentM,
            duration: Pace.duration(
                distanceM: upper - lower, ascentM: ascentM ?? 0, descentM: descentM ?? 0
            ),
            isBehind: isBehind
        )
    }

    /// The corner coordinates of one stretch of the route.
    ///
    /// What a map needs to show a single day rather than the whole trip. Taken
    /// from the same walk of the points the climb figures come from, so a day
    /// framed on the map and a day measured in the panel are the same day.
    public struct Bounds: Sendable, Equatable {
        public let minLat: Double
        public let minLng: Double
        public let maxLat: Double
        public let maxLng: Double
    }

    /// Height above sea level at a point along the route.
    public func elevation(atRouteM routeM: Double) -> Double? {
        var best: (distance: Double, ele: Double)?
        for sample in samples {
            guard let ele = sample.ele else { continue }
            let distance = abs(sample.routeM - routeM)
            if best == nil || distance < best!.distance { best = (distance, ele) }
            // Samples are in order, so once they start receding the nearest is
            // behind us — no reason to walk the remaining eight thousand.
            if sample.routeM > routeM, best != nil { break }
        }
        return best?.ele
    }

    /// How steep the route is around a point, as a percentage.
    ///
    /// Measured over a window rather than between two neighbouring points: at
    /// nineteen metres apart a single pair is mostly the elevation data's own
    /// noise, and a gradient that swings between +40% and −40% while standing
    /// still is worse than none.
    public func gradient(atRouteM routeM: Double, windowM: Double = 150) -> Double? {
        let lower = max(0, routeM - windowM)
        let upper = min(totalM, routeM + windowM)
        guard upper > lower,
              let low = elevation(atRouteM: lower), let high = elevation(atRouteM: upper)
        else { return nil }
        return (high - low) / (upper - lower) * 100
    }

    /// The route's own points across one stretch, in order.
    ///
    /// For drawing a day on top of the trip rather than describing it: the
    /// same geometry the line was built from, so the two sit exactly together
    /// instead of a redrawn approximation shadowing the original.
    public func coordinates(fromRouteM: Double, toRouteM: Double) -> [(lat: Double, lng: Double)] {
        samples
            .filter { $0.routeM >= fromRouteM && $0.routeM <= toRouteM }
            .map { (lat: $0.lat, lng: $0.lng) }
    }

    public func bounds(fromRouteM: Double, toRouteM: Double) -> Bounds? {
        var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
        var minLng = Double.greatestFiniteMagnitude, maxLng = -Double.greatestFiniteMagnitude
        var found = false
        for sample in samples where sample.routeM >= fromRouteM && sample.routeM <= toRouteM {
            found = true
            minLat = min(minLat, sample.lat); maxLat = max(maxLat, sample.lat)
            minLng = min(minLng, sample.lng); maxLng = max(maxLng, sample.lng)
        }
        guard found else { return nil }
        return Bounds(minLat: minLat, minLng: minLng, maxLat: maxLat, maxLng: maxLng)
    }

    // MARK: - Climb

    private func climbBetween(_ startM: Double, _ endM: Double) -> (ascent: Double?, descent: Double?) {
        var ascent = 0.0
        var descent = 0.0
        var run: [Double] = []
        var lastSegment: Int?
        var sawElevation = false

        func flush() {
            if run.count >= 2 {
                let totals = Self.gainLoss(run)
                ascent += totals.ascent
                descent += totals.descent
            }
            run.removeAll(keepingCapacity: true)
        }

        for sample in samples {
            // The epsilon keeps a boundary sample that lands exactly on a
            // checkpoint from falling out over floating-point dust.
            guard sample.routeM >= startM - 1e-6, sample.routeM <= endM + 1e-6 else { continue }
            if let lastSegment, sample.segmentIndex != lastSegment { flush() }
            lastSegment = sample.segmentIndex

            if let ele = sample.ele {
                sawElevation = true
                run.append(ele)
            } else {
                flush()
            }
        }
        flush()

        guard sawElevation else { return (nil, nil) }
        return (ascent, descent)
    }

    /// Smoothed gain and loss over one contiguous run of elevations.
    static func gainLoss(_ elevations: [Double]) -> (ascent: Double, descent: Double) {
        let smoothed = smooth(elevations)
        var ascent = 0.0
        var descent = 0.0
        for index in 1..<smoothed.count {
            let delta = smoothed[index] - smoothed[index - 1]
            if delta > 0 { ascent += delta } else { descent -= delta }
        }
        return (ascent, descent)
    }

    /// Five-point moving average, clamped at both ends.
    static func smooth(_ elevations: [Double]) -> [Double] {
        let count = elevations.count
        var out = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let lower = max(0, index - 2)
            let upper = min(count - 1, index + 2)
            var sum = 0.0
            for k in lower...upper { sum += elevations[k] }
            out[index] = sum / Double(upper - lower + 1)
        }
        return out
    }

    // MARK: - Time

    /// How long a stretch of mountain walking takes.
    ///
    /// The Swiss Alpine Club's Marschzeit method: count the horizontal time and
    /// the vertical time separately, then take the larger plus half the smaller,
    /// on the reasoning that one is partly absorbed into the other — you are not
    /// climbing and covering ground in sequence, you are doing both at once.
    ///
    /// Checked against the route this app was built for. Cicerone gives 6 h 30
    /// for the first Tour du Mont Blanc stage (17 km, 1150 m up, 1210 m down);
    /// these constants give 6 h 31. The two other candidates were tried and
    /// rejected on the same day: Naismith's rule, tuned for British hills, comes
    /// out about an hour fast, and the German DAV variant (300 m/h up, 500 m/h
    /// down) runs nearly two hours slow.
    ///
    /// It is an estimate of *moving* time and says nothing about lunch, photos,
    /// or a queue at a col.
    public enum Pace {
        public static let flatMetresPerHour = 4_000.0
        public static let ascentMetresPerHour = 400.0
        public static let descentMetresPerHour = 800.0

        public static func duration(
            distanceM: Double, ascentM: Double, descentM: Double
        ) -> TimeInterval {
            let horizontal = distanceM / flatMetresPerHour
            let vertical = ascentM / ascentMetresPerHour + descentM / descentMetresPerHour
            let hours = max(horizontal, vertical) + min(horizontal, vertical) / 2
            return hours * 3600
        }
    }
}
