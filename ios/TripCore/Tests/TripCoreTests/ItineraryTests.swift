import Foundation
import Testing
@testable import TripCore

/// Itinerary ordering.
///
/// The numbering has to match the web planner exactly. If the two disagree
/// about which day is "day 7", a walker reading the plan on a laptop and the
/// app on a phone are looking at different days — which is the kind of mismatch
/// that gets noticed at a refuge with no signal.
struct ItineraryTests {
    static func package(
        days: [(boundary: String, name: String)],
        extras: [(before: String, title: String)],
        startDayNumber: Int = 1
    ) throws -> TripPackage {
        let itinerary = days.enumerated().map { index, day in
            """
            {"index":\(index + 1),"startRouteM":\(index * 1000),"endRouteM":\((index + 1) * 1000),
             "distanceM":1000,"startBoundary":"\(day.boundary)","startName":"\(day.name)",
             "endBoundary":"end\(index)","endName":"End \(index)","ascentM":10,"descentM":10,"note":""}
            """
        }.joined(separator: ",")
        let extraDays = extras.enumerated().map { index, extra in
            """
            {"id":"x\(index)","before":"\(extra.before)","title":"\(extra.title)","note":""}
            """
        }.joined(separator: ",")

        let json = """
        {"format":"ulpacker-trip-package","schemaVersion":1,"hashAlgorithm":"fnv1a64",
         "tripId":"t","revision":1,"publishedAt":"2026-01-01T00:00:00.000Z",
         "trip":{"name":"T","description":"","startName":"","finishName":"","loop":false,
                 "startDayNumber":\(startDayNumber)},
         "plannedRoute":{"segments":[{"points":[[45.9,6.8,1],[45.91,6.81,2]]}],
           "stats":{"distanceM":1000,"ascentM":1,"descentM":1,"minEle":1,"maxEle":2,
                    "elevationCoverage":1,"pointCount":2,"segmentCount":1}},
         "checkpoints":[],"itinerary":[\(itinerary)],"extraDays":[\(extraDays)],
         "navigationDefaults":{"offRouteEnterM":75,"offRouteExitM":40},"contentHash":"x"}
        """
        return try JSONDecoder().decode(TripPackage.self, from: Data(json.utf8))
    }

    @Test func numbersWalkingDaysFromOne() throws {
        let package = try Self.package(
            days: [("start", "A"), ("cp1", "B")], extras: []
        )
        let entries = Itinerary.combined(package)
        #expect(entries.map(\.number) == [1, 2])
        let allWalking = entries.allSatisfy { $0.isWalking }
        #expect(allWalking)
    }

    @Test func startsAtDayZeroWhenTheTripHasAPrepDay() throws {
        let package = try Self.package(
            days: [("start", "A")], extras: [("start", "Arrival")], startDayNumber: 0
        )
        let entries = Itinerary.combined(package)
        // An arrival day is Day 0, so the first walking day keeps its familiar
        // number rather than being pushed to 2.
        #expect(entries[0].number == 0)
        #expect(entries[0].title == "Arrival")
        #expect(entries[1].number == 1)
        #expect(entries[1].isWalking)
    }

    @Test func placesAnOffRouteDayBeforeTheDayItNames() throws {
        let package = try Self.package(
            days: [("start", "A"), ("cp1", "B"), ("cp2", "C")],
            extras: [("cp2", "Rest day")]
        )
        let entries = Itinerary.combined(package)
        #expect(entries.map(\.title) == ["A → End 0", "B → End 1", "Rest day", "C → End 2"])
        #expect(entries.map(\.number) == [1, 2, 3, 4])
    }

    @Test func keepsSeveralOffRouteDaysAtTheSameBoundaryInOrder() throws {
        // The real case: a three-day Zermatt excursion inserted at one point in
        // the walk, which must stay in the order it was planned.
        let package = try Self.package(
            days: [("start", "A"), ("cp1", "B")],
            extras: [("cp1", "Travel out"), ("cp1", "Zermatt"), ("cp1", "Travel back")]
        )
        let entries = Itinerary.combined(package)
        #expect(entries.map(\.title) == ["A → End 0", "Travel out", "Zermatt", "Travel back", "B → End 1"])
        #expect(entries.map(\.number) == [1, 2, 3, 4, 5])
    }

    @Test func appendsAFinishDayAtTheEnd() throws {
        let package = try Self.package(
            days: [("start", "A")], extras: [("finish", "Travel home")]
        )
        #expect(Itinerary.combined(package).map(\.title) == ["A → End 0", "Travel home"])
    }

    @Test func keepsAnOrphanedDayRatherThanDroppingIt() throws {
        // The route was edited and the checkpoint this day hung off is gone.
        // Showing it in the wrong place is recoverable; losing a planned day
        // silently is not.
        let package = try Self.package(
            days: [("start", "A")], extras: [("cp_deleted", "Rest day")]
        )
        let entries = Itinerary.combined(package)
        #expect(entries.count == 2)
        #expect(entries.last?.title == "Rest day")
    }

    @Test func distinguishesWalkingDaysFromOffRouteOnes() throws {
        let package = try Self.package(
            days: [("start", "A")], extras: [("finish", "Travel home")]
        )
        let entries = Itinerary.combined(package)
        // The trail screen must never offer to navigate a day with no geometry.
        #expect(entries[0].isWalking)
        #expect(!entries[1].isWalking)
        #expect(Itinerary.walkingDayCount(package) == 1)
    }

    @Test func hasNoOffRouteDaysWhenTheTripHasNone() throws {
        let package = try Self.package(days: [("start", "A"), ("cp1", "B")], extras: [])
        let allWalking = Itinerary.combined(package).allSatisfy { $0.isWalking }
        #expect(allWalking)
    }

    @Test func handlesTheShapeOfARealPlannedTrip() throws {
        // Modelled on a package the web app actually produced: nine walking
        // days, an arrival day before the start, and a three-day excursion
        // inserted mid-walk. The committed fixtures cover none of this —
        // tmb-ccw has no off-route days at all — and this combination is where
        // numbering is easiest to get wrong.
        let package = try Self.package(
            days: (1...9).map { (boundary: $0 == 1 ? "start" : "cp\($0)", name: "D\($0)") },
            extras: [
                ("start", "Les Houches arrival"),
                ("cp7", "Travel to Zermatt"),
                ("cp7", "Zermatt"),
                ("cp7", "Back to the route")
            ],
            startDayNumber: 0
        )
        let entries = Itinerary.combined(package)

        #expect(Itinerary.walkingDayCount(package) == 9)
        #expect(entries.count == 13)
        // Numbering runs unbroken across both kinds, starting at the arrival day.
        #expect(entries.map(\.number) == Array(0..<13))
        #expect(entries.first?.isWalking == false)
        // The excursion stays contiguous and in planned order, immediately
        // before the day it interrupts.
        let excursion = entries.filter { !$0.isWalking }.map(\.title)
        #expect(excursion == ["Les Houches arrival", "Travel to Zermatt", "Zermatt", "Back to the route"])
        let zermattStart = try #require(entries.firstIndex { $0.title == "Travel to Zermatt" })
        #expect(entries[zermattStart + 3].isWalking)
    }
}
