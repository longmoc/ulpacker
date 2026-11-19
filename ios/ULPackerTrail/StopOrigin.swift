import Foundation
import TripCore

/// Where a distance to a stop is measured from — one answer for the stop list,
/// the stop's detail and the card on the map, so they never disagree.
///
/// Walking, it is the walker. Off the route, the walker has no place on it; the
/// last one is used, and said to be approximate, instead of being passed off as
/// "where you are". Before the walk, it is the start of the stop's own day: on
/// a nine-day trip, a stop on day 5 measured from the trailhead was 70 km and
/// four days of climb, which answers nothing anyone planning a day asks.
enum StopOrigin: Equatable {
    /// Recording, on the route.
    case walker(Double)
    /// Recording, off the route: the last place the walker had on it.
    case leftRoute(Double)
    case dayStart(number: Int, routeM: Double)
    /// A trip with no days.
    case tripStart

    static func make(
        for checkpoint: TripPackage.Checkpoint,
        walkerM: Double?,
        walkerOnRoute: Bool,
        scopedDay: TripPackage.Day?,
        package: TripPackage
    ) -> StopOrigin {
        if let walkerM { return walkerOnRoute ? .walker(walkerM) : .leftRoute(walkerM) }
        let at = Double(checkpoint.routeDistanceM)
        // Reading one day, its stops are measured from that day's start — the
        // refuge it begins at included, at 0 rather than at the end of the day
        // before.
        if let scopedDay, at >= Double(scopedDay.startRouteM), at <= Double(scopedDay.endRouteM),
           let number = Itinerary.walkingDay(containing: Double(scopedDay.startRouteM) + 0.5, in: package)?.number {
            return .dayStart(number: number, routeM: Double(scopedDay.startRouteM))
        }
        if let (day, number) = Itinerary.walkingDay(containing: at, in: package) {
            return .dayStart(number: number, routeM: Double(day.startRouteM))
        }
        return .tripStart
    }

    var routeM: Double {
        switch self {
        case .walker(let m), .leftRoute(let m): m
        case .dayStart(_, let m): m
        case .tripStart: 0
        }
    }

    /// Measured from the walker, so "ahead" and "behind" mean something.
    var isLive: Bool {
        switch self {
        case .walker, .leftRoute: true
        case .dayStart, .tripStart: false
        }
    }

    var isApproximate: Bool { if case .leftRoute = self { true } else { false } }

    /// Said under the figures, so "4.2 km" never has to be guessed at.
    var description: String {
        switch self {
        case .walker: "from where you are"
        case .leftRoute: "from where you left the route — approximate"
        case .dayStart(let number, _): "from the start of day \(number)"
        case .tripStart: "from the start of the route"
        }
    }
}
