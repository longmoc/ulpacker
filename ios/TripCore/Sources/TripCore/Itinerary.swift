import Foundation

/// Merges walking days and off-route days into the single numbered sequence a
/// walker actually experiences.
///
/// Off-route days are travel, rest, or a side trip — the Zermatt excursion in
/// the middle of a Tour du Mont Blanc, an arrival day before the walk starts.
/// They carry no geometry, so they are never navigated: on those days the
/// walker simply pauses the recording. But they still occupy a numbered slot,
/// and an itinerary that skipped them would not match the plan in anyone's head.
///
/// The ordering rules mirror `ItineraryDays.jsx` in the web planner. That is a
/// deliberate duplication — the same trip must number its days identically on
/// both, or the two disagree about what "day 7" means.
public enum Itinerary {
    public enum Entry: Sendable, Equatable {
        /// A day walked along the route.
        case walking(TripPackage.Day, number: Int)
        /// A day away from the route. No geometry, nothing to follow.
        case offRoute(TripPackage.ExtraDay, number: Int)

        public var number: Int {
            switch self {
            case .walking(_, let number), .offRoute(_, let number): number
            }
        }

        public var title: String {
            switch self {
            case .walking(let day, _):
                "\(day.startName) → \(day.endName)"
            case .offRoute(let day, _):
                day.title
            }
        }

        public var isWalking: Bool {
            if case .walking = self { return true }
            return false
        }
    }

    /// The full itinerary, in order.
    ///
    /// An off-route day is placed before the walking day whose boundary it
    /// names. Anything left over — `finish`, or a boundary that no longer
    /// exists because the route was edited — is appended rather than dropped:
    /// losing a planned day silently is worse than showing it in the wrong
    /// place, where it is at least visible enough to fix.
    public static func combined(_ package: TripPackage) -> [Entry] {
        let days = package.itinerary
        let extras = package.extraDays
        let boundaries = Set(days.map(\.startBoundary))

        var entries: [Entry] = []
        // Trips with a prep or arrival day number the first card Day 0.
        var number = package.trip.startDayNumber == 0 ? 0 : 1

        for day in days {
            for extra in extras where extra.before == day.startBoundary {
                entries.append(.offRoute(extra, number: number))
                number += 1
            }
            entries.append(.walking(day, number: number))
            number += 1
        }

        for extra in extras where extra.before == "finish" || !boundaries.contains(extra.before) {
            entries.append(.offRoute(extra, number: number))
            number += 1
        }

        return entries
    }

    /// How many days the walker is actually on the trail — the number that
    /// matters for food and fuel, as distinct from the length of the trip.
    public static func walkingDayCount(_ package: TripPackage) -> Int {
        package.itinerary.count
    }
}
