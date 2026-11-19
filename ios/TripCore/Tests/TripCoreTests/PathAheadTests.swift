import Foundation
import Testing
@testable import TripCore

/// The shape of the path ahead. What matters is the picture reading the right
/// way round: the route's own direction up, a bend to the walker's left drawn
/// to the left, a walker beside the route drawn beside it.
struct PathAheadTests {
    /// About 1.1 m per 0.00001°: an L-shaped route, north for ~550 m and then
    /// west for ~550 m.
    static func lRoute(thenEast: Bool = false) -> RouteIndex {
        var points: [TrackPoint] = []
        for i in 0...50 { points.append(TrackPoint(lat: 45.9 + Double(i) * 0.0001, lng: 6.8, ele: nil)) }
        let turnLat = 45.9 + 50 * 0.0001
        for i in 1...70 {
            let step = Double(i) * 0.0001 * (thenEast ? 1 : -1)
            points.append(TrackPoint(lat: turnLat, lng: 6.8 + step, ele: nil))
        }
        return RouteIndex(segments: [TripPackage.Segment(points: points)])
    }

    @Test func theRoutesOwnDirectionPointsUp() throws {
        let index = Self.lRoute()
        let path = try #require(PathAhead.make(index: index, routeM: 100, fix: (45.9 + 9 * 0.0001, 6.8)))
        // Straight ahead along the first leg: x stays near zero, y grows.
        let ahead = path.points.filter { $0.y > 0 && $0.y < 400 }
        #expect(!ahead.isEmpty)
        #expect(ahead.allSatisfy { abs($0.x) <= 2 })
        #expect(path.points.contains { $0.y < 0 })
    }

    @Test func aBendToTheLeftIsDrawnToTheLeft() throws {
        let path = try #require(PathAhead.make(index: Self.lRoute(), routeM: 300, fix: (45.9 + 27 * 0.0001, 6.8)))
        #expect(try #require(path.points.last).x < -100)
    }

    @Test func aBendToTheRightIsDrawnToTheRight() throws {
        let path = try #require(PathAhead.make(index: Self.lRoute(thenEast: true), routeM: 300, fix: (45.9 + 27 * 0.0001, 6.8)))
        #expect(try #require(path.points.last).x > 100)
    }

    @Test func itStopsAFewHundredMetresAhead() throws {
        let path = try #require(PathAhead.make(index: Self.lRoute(), routeM: 40, fix: (45.9 + 4 * 0.0001, 6.8)))
        // From 40 m, 500 m ahead ends at 540 m, short of the turn at ~556 m.
        #expect(abs(try #require(path.points.last).y - 500) <= 5)
        #expect(path.points.count <= 30)
    }

    @Test func aWalkerEastOfANorthboundRouteIsOnItsRight() throws {
        // ~80 m east of the route.
        let path = try #require(PathAhead.make(index: Self.lRoute(), routeM: 100, fix: (45.9 + 9 * 0.0001, 6.801)))
        #expect(path.walker.x > 60)
        #expect(abs(path.walker.y) < 20)
    }

    // MARK: - Off the route

    /// ~250 m east of the northbound first leg, level with its 100 m mark.
    static let eastOfRoute = (lat: 45.9 + 9 * 0.0001, lng: 6.8 + 0.0032)

    @Test func offTheRouteThePictureTurnsWithTheWalker() throws {
        // Walking east, away from the route: the way back is behind.
        let away = try #require(PathAhead.make(index: Self.lRoute(), routeM: 100, fix: Self.eastOfRoute,
                                               offRoute: true, walkerCourse: 90))
        let back = try #require(away.backTo)
        #expect(back.y < away.walker.y - 50)

        // Walking west, towards it: the way back is ahead.
        let towards = try #require(PathAhead.make(index: Self.lRoute(), routeM: 100, fix: Self.eastOfRoute,
                                                  offRoute: true, walkerCourse: 270))
        #expect(try #require(towards.backTo).y > towards.walker.y + 50)

        // Walking north, alongside it: the way back is to the left.
        let along = try #require(PathAhead.make(index: Self.lRoute(), routeM: 100, fix: Self.eastOfRoute,
                                                offRoute: true, walkerCourse: 0))
        #expect(try #require(along.backTo).x < along.walker.x - 50)
    }

    @Test func farOffTheWalkerIsDrawnNearEnoughToKeepTheRouteInSight() throws {
        let far = (lat: 45.9 + 9 * 0.0001, lng: 6.8 + 0.02)   // ~1.5 km east
        let path = try #require(PathAhead.make(index: Self.lRoute(), routeM: 100, fix: far,
                                               offRoute: true, walkerCourse: 0))
        let drawn = hypot(Double(path.walker.x), Double(path.walker.y))
        #expect(drawn <= PathAhead.maxDrawnOffM + 1)
        #expect(drawn >= PathAhead.maxDrawnOffM - 1)
    }

    @Test func theWayBackIsToWhereverTheRouteIsNearestNow() throws {
        // The matcher still holds 100 m, but the walker has wandered to beside
        // the far end of the second leg.
        let index = Self.lRoute()
        let nearEnd = (lat: 45.9 + 50 * 0.0001 + 0.0005, lng: 6.8 - 60 * 0.0001)
        let path = try #require(PathAhead.make(index: index, routeM: 100, fix: nearEnd,
                                               offRoute: true, walkerCourse: 0))
        let drawn = hypot(Double(path.walker.x), Double(path.walker.y))
        #expect(drawn < 80)
    }

    @Test func onTheRouteThereIsNoWayBack() throws {
        let path = try #require(PathAhead.make(index: Self.lRoute(), routeM: 100, fix: (45.9 + 9 * 0.0001, 6.8)))
        #expect(path.backTo == nil)
    }

    @Test func theNextStopIsMarkedOnlyWhenItIsInSight() throws {
        let index = Self.lRoute()
        let fix = (lat: 45.9 + 9 * 0.0001, lng: 6.8)
        let near = try #require(PathAhead.make(index: index, routeM: 100, fix: fix, stopAtM: 400))
        #expect(near.stop != nil)
        let far = try #require(PathAhead.make(index: index, routeM: 100, fix: fix, stopAtM: 900))
        #expect(far.stop == nil)
    }

    @Test func nearTheEndTheLastStretchStillGivesTheDirection() throws {
        let index = Self.lRoute()
        let path = try #require(PathAhead.make(index: index, routeM: index.totalM - 5, fix: (45.905, 6.7932)))
        #expect(path.points.count >= 2)
    }

    @Test func theCardSaysOffRouteBeforeAnythingElse() throws {
        let planner = DayPlanner(package: try RouteProfileTests.package("tmb-ccw"))
        let guidance = planner.guidance(routeM: 20_000, onRoute: false, fix: (45.8, 6.7), at: DayPlannerTests.now)
        let progress = RecordingSession.Progress(
            routeDistanceM: 20_000, remainingM: 1, offsetM: 120, walkedM: 0, lat: 0, lng: 0,
            fixLat: 45.8, fixLng: 6.7, courseDegrees: nil, confidence: .distant, offRouteState: .offRoute,
            shouldAlertOffRoute: false, shouldAlertNoFix: false, nextCheckpoint: nil,
            distanceToNextCheckpointM: nil, fixCount: 1, rejectedFixCount: 0
        )
        let card = TrailCardState.make(guidance: guidance, progress: progress, path: nil, paused: false, clock: { _ in "12:00" })
        #expect(card.status == .offRoute)
        #expect(card.statusDetail == "120 m")
        #expect(card.title.hasPrefix("Day 2 · — /"))
        #expect(card.next?.contains("straight") == true)
    }

    @Test func theCardFitsWhatALiveActivityMaySend() throws {
        let path = try #require(PathAhead.make(index: Self.lRoute(), routeM: 300, fix: (45.9 + 27 * 0.0001, 6.8), stopAtM: 500))
        let card = TrailCardState(
            status: .onRoute, statusDetail: nil,
            title: "Day 2 · 12.4 / 16.3 km",
            next: "Day 2 — Aire de bivouac des Chapieux (verify late-season opening) · 3.9 km · 15:40",
            nextSymbol: "tent.fill", nextShort: "3.9 km",
            daylight: "↑620 m left · arrive 17:20 · sunset 19:12", daylightLevel: 0, path: path
        )
        // ActivityKit refuses content over 4 KB.
        #expect(try JSONEncoder().encode(card).count < 2_000)
    }
}
