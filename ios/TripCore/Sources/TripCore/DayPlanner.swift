import Foundation

/// What is left of today, and what comes next: the numbers a walker wants at a
/// glance while walking.
///
/// Today is decided by where the walker is on the route, not by the calendar. A
/// walk runs late, a rest day gets added, and "day 3" stays the stretch they are
/// actually on.
///
/// A fix arrives every 15 m and this must not add to what that costs, so the
/// climb of each day is added up once, here, and every later question is a
/// binary search — never another walk along thousands of route points. The
/// figures can differ from `RouteProfile.leg` by a few metres, because a stretch
/// is smoothed once across the day rather than separately for each leg.
public struct DayPlanner: Sendable {
    /// The stretch of route the walker is on, and everything worth knowing about
    /// the rest of it.
    public struct Guidance: Sendable, Equatable {
        /// The day's number as the trip list shows it; nil for a trip with no
        /// days, where the stretch is the whole route.
        public let dayNumber: Int?
        public let totalM: Double
        /// Nil when the walker is not on the route, where a position along it
        /// would be a guess.
        public let doneM: Double?
        public let leftM: Double?
        public let ascentLeftM: Double?
        public let timeLeft: TimeInterval?
        public let arrival: Date?
        public let sunset: Date?
        /// Daylight left after arriving; negative when arrival is after sunset.
        public let spareDaylight: TimeInterval?
        /// Within a few metres of the end of the day.
        public let arrived: Bool
        public let next: Stop
    }

    public struct Stop: Sendable, Equatable {
        public let name: String
        /// Nil for a day's end with no checkpoint at it.
        public let kind: CheckpointKind?
        public let isDayEnd: Bool
        public let distanceM: Double
        /// Measured across the ground rather than along the route, because the
        /// walker is not on it.
        public let isStraightLine: Bool
        public let ascentM: Double?
        public let arrival: Date?
    }

    /// One day's stretch of the route, with its climb added up.
    struct Stretch: Sendable {
        let number: Int?
        let startM: Double
        let endM: Double
        let endName: String
        let endLat: Double
        let endLng: Double
        let stops: [TripPackage.Checkpoint]
        let routeM: [Double]
        let ascent: [Double]
        let descent: [Double]
        let hasElevation: Bool

        private func cumulative(_ values: [Double], at m: Double) -> Double {
            guard let first = routeM.first, let last = routeM.last, m > first else { return values.first ?? 0 }
            guard m < last else { return values[values.count - 1] }
            var low = 0, high = routeM.count - 1
            while high - low > 1 {
                let mid = (low + high) / 2
                if routeM[mid] <= m { low = mid } else { high = mid }
            }
            let span = routeM[high] - routeM[low]
            let t = span > 0 ? (m - routeM[low]) / span : 0
            return values[low] + (values[high] - values[low]) * t
        }

        func climb(from a: Double, to b: Double) -> (ascent: Double, descent: Double)? {
            guard hasElevation else { return nil }
            return (max(0, cumulative(ascent, at: b) - cumulative(ascent, at: a)),
                    max(0, cumulative(descent, at: b) - cumulative(descent, at: a)))
        }

        func plannedTime(from a: Double, to b: Double) -> TimeInterval {
            let climb = climb(from: a, to: b)
            return RouteProfile.Pace.duration(
                distanceM: max(0, b - a), ascentM: climb?.ascent ?? 0, descentM: climb?.descent ?? 0
            )
        }
    }

    /// How near the end of a day still counts as having reached it, and as not
    /// yet having set off on the next: GPS will not land on the exact metre.
    static let arrivalM = 50.0
    /// A checkpoint this near the end of the day is the end of the day.
    static let dayEndM = 150.0
    /// What a walker plans the day around. Viewpoints and points of interest are
    /// worth seeing but nobody asks how far to the next one.
    static let plannedAround: Set<CheckpointKind> = [
        .overnight, .refuge, .water, .food, .resupply, .pass, .hazard,
    ]

    let stretches: [Stretch]

    public init(package: TripPackage) {
        let profile = RouteProfile(package: package)
        let stops = package.checkpoints.filter { Self.plannedAround.contains($0.checkpointKind) }

        var numbers: [Int: Int] = [:]
        for case let .walking(day, number) in Itinerary.combined(package) { numbers[day.index] = number }

        var stretches = package.itinerary.map { day in
            Self.stretch(
                number: numbers[day.index],
                startM: Double(day.startRouteM),
                endM: Double(day.endRouteM),
                endName: day.endName,
                profile: profile,
                stops: stops
            )
        }
        if stretches.isEmpty {
            stretches = [Self.stretch(
                number: nil, startM: 0, endM: profile.totalM,
                endName: package.trip.finishName, profile: profile, stops: stops
            )]
        }
        self.stretches = stretches
    }

    private static func stretch(
        number: Int?, startM: Double, endM: Double, endName: String,
        profile: RouteProfile, stops: [TripPackage.Checkpoint]
    ) -> Stretch {
        let samples = profile.samples.filter { $0.routeM >= startM - 1e-6 && $0.routeM <= endM + 1e-6 }
        var ascent = [Double](repeating: 0, count: samples.count)
        var descent = ascent
        var hasElevation = false

        // Runs split where RouteProfile splits them: at a gap in the route and
        // at a point with no elevation, neither of which is a climb.
        var runStart = 0
        func closeRun(before end: Int) {
            let run = samples[runStart..<end].compactMap(\.ele)
            guard run.count == end - runStart, run.count >= 2 else { return }
            hasElevation = true
            let smoothed = RouteProfile.smooth(run)
            for offset in 1..<run.count {
                let delta = smoothed[offset] - smoothed[offset - 1]
                let at = runStart + offset
                ascent[at] = delta > 0 ? delta : 0
                descent[at] = delta < 0 ? -delta : 0
            }
        }
        for index in samples.indices.dropFirst() {
            let previous = samples[index - 1], sample = samples[index]
            if sample.segmentIndex != previous.segmentIndex || sample.ele == nil || previous.ele == nil {
                closeRun(before: index)
                runStart = index
            }
        }
        closeRun(before: samples.count)
        for index in samples.indices.dropFirst() {
            ascent[index] += ascent[index - 1]
            descent[index] += descent[index - 1]
        }

        return Stretch(
            number: number,
            startM: startM,
            endM: endM,
            endName: endName,
            endLat: samples.last?.lat ?? 0,
            endLng: samples.last?.lng ?? 0,
            stops: stops.filter { Double($0.routeDistanceM) >= startM && Double($0.routeDistanceM) <= endM },
            routeM: samples.map(\.routeM),
            ascent: ascent,
            descent: descent,
            hasElevation: hasElevation
        )
    }

    func stretchIndex(atRouteM routeM: Double) -> Int {
        stretches.firstIndex { routeM <= $0.endM + Self.arrivalM } ?? stretches.count - 1
    }

    /// What to tell the walker at this position.
    ///
    /// - Parameters:
    ///   - onRoute: whether `routeM` is really where the walker is, rather than
    ///     just the nearest point of a route they are not on.
    ///   - fix: where the receiver says they are, for a straight-line distance
    ///     when they are not on the route.
    ///   - paceFactor: how the walker's own pace compares with the plan, from
    ///     `PaceTracker`; nil means no evidence yet, so the plan stands.
    public func guidance(
        routeM: Double,
        onRoute: Bool,
        fix: (lat: Double, lng: Double)?,
        at now: Date,
        paceFactor: Double? = nil,
        calendar: Calendar = .current
    ) -> Guidance {
        let stretch = stretches[stretchIndex(atRouteM: routeM)]
        let here = min(max(routeM, stretch.startM), stretch.endM)
        let factor = paceFactor ?? 1

        let leftM = stretch.endM - here
        let timeLeft = onRoute ? stretch.plannedTime(from: here, to: stretch.endM) * factor : nil
        let arrival = timeLeft.map { now.addingTimeInterval($0) }
        let sunset = SunTimes.sunset(
            latitude: stretch.endLat, longitude: stretch.endLng, on: now, calendar: calendar
        )
        let spare: TimeInterval? = if let arrival, let sunset { sunset.timeIntervalSince(arrival) } else { nil }

        return Guidance(
            dayNumber: stretch.number,
            totalM: stretch.endM - stretch.startM,
            doneM: onRoute ? here - stretch.startM : nil,
            leftM: onRoute ? leftM : nil,
            ascentLeftM: onRoute ? stretch.climb(from: here, to: stretch.endM)?.ascent : nil,
            timeLeft: timeLeft,
            arrival: arrival,
            sunset: sunset,
            spareDaylight: spare,
            arrived: onRoute && routeM >= stretch.endM - Self.arrivalM,
            next: nextStop(in: stretch, from: here, onRoute: onRoute, fix: fix, at: now, factor: factor)
        )
    }

    private func nextStop(
        in stretch: Stretch, from here: Double, onRoute: Bool,
        fix: (lat: Double, lng: Double)?, at now: Date, factor: Double
    ) -> Stop {
        let checkpoint = stretch.stops.first { Double($0.routeDistanceM) > here }
        let atM = checkpoint.map { Double($0.routeDistanceM) } ?? stretch.endM
        let target = checkpoint.map { (lat: $0.lat, lng: $0.lng) } ?? (lat: stretch.endLat, lng: stretch.endLng)

        let distance: Double = if !onRoute, let fix {
            ActivityJournal.haversine(fix.lat, fix.lng, target.lat, target.lng)
        } else {
            atM - here
        }
        return Stop(
            name: checkpoint?.name ?? stretch.endName,
            kind: checkpoint?.checkpointKind,
            isDayEnd: atM >= stretch.endM - Self.dayEndM,
            distanceM: distance,
            isStraightLine: !onRoute,
            ascentM: onRoute ? stretch.climb(from: here, to: atM)?.ascent : nil,
            arrival: onRoute ? now.addingTimeInterval(stretch.plannedTime(from: here, to: atM) * factor) : nil
        )
    }
}

/// How the walker's own pace compares with the plan, today.
///
/// Time only counts while the route is going by. A long stop leaves a gap
/// between fixes and is dropped, so lunch does not make the afternoon look slow;
/// a detour or a walk back along the route adds nothing to the planned side and
/// no time to the actual one. A shuttle, far too fast for feet, starts afresh.
public struct PaceTracker: Sendable, Equatable {
    /// Below this there is too little to go on: the first kilometre says more
    /// about the car park than about the walker.
    static let minimumM = 1_000.0
    static let minimumS: TimeInterval = 900
    /// A longer gap between fixes is a stop, not slow walking.
    static let longestStepS: TimeInterval = 300
    /// Faster than this is not on foot; the same limit as `WalkedDistance`.
    static let fastestMPS = 5.5
    /// A jitter backwards along the line is not a walk back.
    static let backwardToleranceM = 30.0

    private var stretch: Int?
    private var last: (m: Double, t: Date)?
    private var runStartM: Double?
    private var finishedPlanned: TimeInterval = 0
    private var runPlanned: TimeInterval = 0
    private var actual: TimeInterval = 0
    private var coveredM = 0.0

    public init() {}

    public static func == (a: PaceTracker, b: PaceTracker) -> Bool {
        a.stretch == b.stretch && a.actual == b.actual && a.coveredM == b.coveredM
    }

    /// Actual time over planned: above 1 is slower than the plan. Bounded, so
    /// one odd stretch cannot produce an arrival time nobody would believe.
    public var factor: Double? {
        let planned = finishedPlanned + runPlanned
        guard coveredM >= Self.minimumM, actual >= Self.minimumS, planned > 0 else { return nil }
        return min(2.5, max(0.5, actual / planned))
    }

    public mutating func observe(routeM: Double, at time: Date, planner: DayPlanner) {
        let index = planner.stretchIndex(atRouteM: routeM)
        if index != stretch {
            self = PaceTracker()
            stretch = index
        }
        guard let previous = last else {
            last = (routeM, time)
            runStartM = routeM
            return
        }
        let dr = routeM - previous.m
        if dr < 0, dr >= -Self.backwardToleranceM { return }

        let dt = time.timeIntervalSince(previous.t)
        guard dr > 0, dt > 0, dt <= Self.longestStepS, dr / dt <= Self.fastestMPS else {
            finishedPlanned += runPlanned
            runPlanned = 0
            runStartM = routeM
            last = (routeM, time)
            return
        }
        actual += dt
        coveredM += dr
        last = (routeM, time)
        if let runStartM {
            runPlanned = planner.stretches[index].plannedTime(from: runStartM, to: routeM)
        }
    }
}
