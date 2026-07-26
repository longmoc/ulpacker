import Foundation

/// What recording the rest of the trip will cost, day by day.
///
/// A single day's drain is a curiosity. On a nine-day walk it is a planning
/// constraint: some nights on this route are a refuge with a socket and some
/// are a bivouac with nothing, and the question "can I record tomorrow"
/// deserves an answer before the walker is standing at the col.
///
/// The arithmetic is deliberately shallow — measured rate times estimated
/// walking hours — because every part of it is already something the app knows
/// honestly. The hours come from the same Alpine club estimate the stop details
/// use, and the rate comes from a real recording on the real phone. Nothing
/// here is a manufacturer figure or a community number.
public enum BatteryForecast {
    public struct Day: Sendable, Equatable {
        public let number: Int
        public let title: String
        public let distanceM: Double
        public let hours: Double
        /// Battery the recording is expected to use, in percentage points.
        public let percent: Double
        /// True when one full charge would not see the day out.
        public let exceedsFullCharge: Bool
    }

    public struct Result: Sendable, Equatable {
        public let days: [Day]
        public let percentPerHour: Double
        /// Reserve held back, in percentage points — a phone that reaches a
        /// refuge at 0% is also a phone with no torch and no way to call.
        public let reservePercent: Double

        public var totalHours: Double { days.reduce(0) { $0 + $1.hours } }
        public var totalPercent: Double { days.reduce(0) { $0 + $1.percent } }
        /// The day that decides whether this works at all.
        public var worstDay: Day? { days.max { $0.percent < $1.percent } }
        /// How many full charges the whole trip needs, if nothing else drew
        /// power. A floor on the answer, never the answer.
        public var chargesNeeded: Double { totalPercent / (100 - reservePercent) }
    }

    /// Project the trip from a measured rate.
    ///
    /// Covers recording only. It says nothing about the phone sitting in a tent
    /// overnight, about photographs, or about a morning spent looking at the
    /// map — and a forecast that quietly folded in guesses for those would be
    /// less useful than one that is clear about its edges.
    public static func make(
        package: TripPackage,
        profile: RouteProfile,
        percentPerHour: Double,
        reservePercent: Double = 15
    ) -> Result {
        let numbers = Dictionary(
            uniqueKeysWithValues: Itinerary.combined(package).compactMap { entry -> (String, Int)? in
                guard case .walking(let day, let number) = entry else { return nil }
                return ("\(day.index)", number)
            }
        )

        let days = package.itinerary.map { day -> Day in
            let leg = profile.leg(
                fromRouteM: Double(day.startRouteM), toRouteM: Double(day.endRouteM)
            )
            let hours = (leg.duration ?? 0) / 3600
            let percent = hours * percentPerHour
            return Day(
                number: numbers["\(day.index)"] ?? day.index,
                title: "\(day.startName) → \(day.endName)",
                distanceM: leg.distanceM,
                hours: hours,
                percent: (percent * 10).rounded() / 10,
                exceedsFullCharge: percent > 100 - reservePercent
            )
        }

        return Result(days: days, percentPerHour: percentPerHour, reservePercent: reservePercent)
    }
}
