import Foundation
import Testing
@testable import TripCore

/// The numbers a walker reads at a glance. The first test is the load-bearing
/// one: a day's climb here must be the planner's, or the phone contradicts the
/// laptop on the figure that decides whether to go on.
struct DayPlannerTests {
    static let now = Date(timeIntervalSince1970: 1_789_000_000)

    @Test func aDaysClimbIsTheOneThePlannerComputed() throws {
        let package = try RouteProfileTests.package("tmb-ccw")
        let planner = DayPlanner(package: package)
        for (day, stretch) in zip(package.itinerary, planner.stretches) {
            let climb = try #require(stretch.climb(from: stretch.startM, to: stretch.endM))
            #expect(abs(climb.ascent - Double(try #require(day.ascentM))) <= 2)
            #expect(abs(climb.descent - Double(try #require(day.descentM))) <= 2)
        }
    }

    @Test func aLegWithinADayAgreesWithTheStopsPanelToWithinAFewMetres() throws {
        let package = try RouteProfileTests.package("tmb-ccw")
        let profile = RouteProfile(package: package)
        let stretch = DayPlanner(package: package).stretches[1]
        let from = stretch.startM + 4_000
        let climb = try #require(stretch.climb(from: from, to: stretch.endM))
        let leg = profile.leg(fromRouteM: from, toRouteM: stretch.endM)
        #expect(abs(climb.ascent - (leg.ascentM ?? 0)) <= 10)
    }

    @Test func todayIsWhereTheWalkerIsNotWhatTheCalendarSays() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        let guidance = planner.guidance(routeM: 20_000, onRoute: true, fix: nil, at: Self.now)
        #expect(guidance.dayNumber == 2)
        #expect(abs(try #require(guidance.doneM) - 1_097) < 1)
        #expect(abs(try #require(guidance.leftM) - 15_247) < 1)
    }

    @Test func standingAtTheRefugeIsStillArrivingUntilTheWalkerSetsOff() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        let arriving = planner.guidance(routeM: 18_880, onRoute: true, fix: nil, at: Self.now)
        #expect(arriving.dayNumber == 1)
        #expect(arriving.arrived)

        let justPast = planner.guidance(routeM: 18_930, onRoute: true, fix: nil, at: Self.now)
        #expect(justPast.dayNumber == 1)
        #expect(justPast.arrived)

        let setOff = planner.guidance(routeM: 19_000, onRoute: true, fix: nil, at: Self.now)
        #expect(setOff.dayNumber == 2)
        #expect(!setOff.arrived)
    }

    @Test func theNextStopSkipsWhatNobodyPlansAround() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        // A point of interest sits at 21,825 and water at 22,132.
        let guidance = planner.guidance(routeM: 21_000, onRoute: true, fix: nil, at: Self.now)
        #expect(guidance.next.kind == .water)
        #expect(abs(guidance.next.distanceM - 1_132) < 1)
        #expect(!guidance.next.isDayEnd)
    }

    @Test func aDayEndWithNoCheckpointIsStillANextStop() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("synthetic-ridge"))
        let end = try #require(planner.stretches.last)
        let guidance = planner.guidance(routeM: end.endM - 300, onRoute: true, fix: nil, at: Self.now)
        #expect(guidance.next.isDayEnd)
        #expect(guidance.next.distanceM <= 300)
    }

    @Test func offTheRouteOnlyTheStraightLineIsKnown() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        let guidance = planner.guidance(
            routeM: 21_000, onRoute: false, fix: (lat: 45.80, lng: 6.70), at: Self.now
        )
        #expect(guidance.doneM == nil)
        #expect(guidance.arrival == nil)
        #expect(guidance.spareDaylight == nil)
        #expect(guidance.next.isStraightLine)
        #expect(guidance.next.arrival == nil)
        #expect(guidance.next.ascentM == nil)
    }

    @Test func aTripWithNoDaysIsOneLongDay() throws {
        let package = try RouteProfileTests.package(elevations: Array(repeating: 100, count: 100))
        let planner = DayPlanner(package: package)
        let guidance = planner.guidance(routeM: 50, onRoute: true, fix: nil, at: Self.now)
        #expect(guidance.dayNumber == nil)
        #expect(guidance.totalM > 100)
    }

    @Test func noElevationIsNotAFlatWalk() throws {
        let package = try RouteProfileTests.package(elevations: Array(repeating: nil, count: 100))
        let guidance = DayPlanner(package: package).guidance(routeM: 10, onRoute: true, fix: nil, at: Self.now)
        #expect(guidance.ascentLeftM == nil)
    }

    @Test func arrivalMovesWithTheWalkersOwnPace() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        let plan = planner.guidance(routeM: 20_000, onRoute: true, fix: nil, at: Self.now)
        let slow = planner.guidance(routeM: 20_000, onRoute: true, fix: nil, at: Self.now, paceFactor: 1.5)
        let planLeft = try #require(plan.timeLeft)
        #expect(abs(try #require(slow.timeLeft) - planLeft * 1.5) < 0.001)
        #expect(try #require(slow.spareDaylight) < (try #require(plan.spareDaylight)))
    }

    // MARK: - Pace

    /// A walk along the second TMB day at a steady speed.
    private func walk(
        _ tracker: inout PaceTracker, planner: DayPlanner,
        fromM: Double, toM: Double, metresPerSecond: Double, start: Date
    ) -> Date {
        var time = start
        var m = fromM
        while m < toM {
            tracker.observe(routeM: m, at: time, planner: planner)
            m += 15
            time = time.addingTimeInterval(15 / metresPerSecond)
        }
        return time
    }

    @Test func tooLittleWalkingSaysNothing() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        var tracker = PaceTracker()
        _ = walk(&tracker, planner: planner, fromM: 20_000, toM: 20_500, metresPerSecond: 1, start: Self.now)
        #expect(tracker.factor == nil)
    }

    @Test func aSlowWalkerReadsSlowerThanAFastOne() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        var slow = PaceTracker(), fast = PaceTracker()
        _ = walk(&slow, planner: planner, fromM: 20_000, toM: 23_000, metresPerSecond: 0.7, start: Self.now)
        _ = walk(&fast, planner: planner, fromM: 20_000, toM: 23_000, metresPerSecond: 1.4, start: Self.now)
        #expect(try #require(slow.factor) > (try #require(fast.factor)))
    }

    @Test func lunchDoesNotMakeTheAfternoonLookSlow() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        var straight = PaceTracker(), withLunch = PaceTracker()
        _ = walk(&straight, planner: planner, fromM: 20_000, toM: 23_000, metresPerSecond: 1, start: Self.now)

        let end = walk(&withLunch, planner: planner, fromM: 20_000, toM: 21_500, metresPerSecond: 1, start: Self.now)
        _ = walk(&withLunch, planner: planner, fromM: 21_500, toM: 23_000, metresPerSecond: 1,
                 start: end.addingTimeInterval(3_600))
        #expect(abs(try #require(withLunch.factor) - (try #require(straight.factor))) < 0.1)
    }

    @Test func aShuttleIsNotFastWalking() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        var tracker = PaceTracker()
        let end = walk(&tracker, planner: planner, fromM: 20_000, toM: 22_000, metresPerSecond: 1, start: Self.now)
        let before = try #require(tracker.factor)
        // Five kilometres in five minutes.
        tracker.observe(routeM: 27_000, at: end.addingTimeInterval(300), planner: planner)
        #expect(abs(try #require(tracker.factor) - before) < 0.01)
    }

    @Test func aNewDayStartsAfresh() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        var tracker = PaceTracker()
        let end = walk(&tracker, planner: planner, fromM: 10_000, toM: 13_000, metresPerSecond: 1, start: Self.now)
        #expect(tracker.factor != nil)
        tracker.observe(routeM: 20_000, at: end.addingTimeInterval(50_000), planner: planner)
        #expect(tracker.factor == nil)
    }

    // MARK: - Sunset

    private func utc(_ year: Int, _ month: Int, _ day: Int) -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return (calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!, calendar)
    }

    private func minutes(_ date: Date, _ calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return parts.hour! * 60 + parts.minute!
    }

    @Test func sunsetAgreesWithTheAlmanac() throws {
        // London, 20 June 2024: 21:21 BST, 20:21 UTC.
        let (london, calendar) = utc(2024, 6, 20)
        let set = try #require(SunTimes.sunset(latitude: 51.5074, longitude: -0.1278, on: london, calendar: calendar))
        #expect(abs(minutes(set, calendar) - (20 * 60 + 21)) <= 3)

        // New York, 4 July 2024: 20:31 EDT, 00:31 UTC the next day.
        let (newYork, _) = utc(2024, 7, 4)
        let setNY = try #require(SunTimes.sunset(latitude: 40.7128, longitude: -74.0060, on: newYork, calendar: calendar))
        #expect(abs(minutes(setNY, calendar) - 31) <= 3)
    }

    @Test func thePolarSummerHasNoSunset() {
        let (june, calendar) = utc(2024, 6, 21)
        #expect(SunTimes.sunset(latitude: 69.65, longitude: 18.96, on: june, calendar: calendar) == nil)
    }
}
