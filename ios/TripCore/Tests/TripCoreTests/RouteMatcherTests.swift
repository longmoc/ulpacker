import Foundation
import Testing
@testable import TripCore

/// Matcher and off-route tests, run against the real Tour du Mont Blanc route.
///
/// The synthetic cases below are deliberately the awkward ones — a loop
/// approaching itself, an out-and-back overlapping its own line, a teleport, a
/// phone drifting while stationary. Those are where nearest-edge matching is
/// wrong in a way that a straight-line test would never reveal.
struct RouteMatcherTests {
    static func tmb() throws -> TripPackage {
        try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
    }

    static func fix(
        _ seq: Int,
        _ lat: Double,
        _ lng: Double,
        at seconds: Double,
        hAcc: Double = 8
    ) -> ActivityPackage.Fix {
        ActivityPackage.Fix(
            seq: seq,
            t: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            lat: lat,
            lng: lng,
            hAcc: hAcc
        )
    }

    /// A straight west–east line, 10 points about 78 m apart.
    static func straightRoute() -> RouteIndex {
        let points = (0..<10).map { TrackPoint(lat: 45.9, lng: 6.8 + Double($0) * 0.001, ele: 1000) }
        return RouteIndex(segments: [TripPackage.Segment(points: points)])
    }

    // MARK: - Index

    @Test func indexesTheWholeRealRoute() throws {
        let index = RouteIndex(segments: try Self.tmb().plannedRoute.segments)
        #expect(index.edges.count == 8560) // 8561 points, one segment
        // Independently accumulated edge lengths must land on the distance the
        // planner published — the two sides measuring the same route.
        #expect(abs(index.totalM - 164_231) < 200)
    }

    @Test func findsAPointExactlyOnTheRoute() throws {
        let package = try Self.tmb()
        let index = RouteIndex(segments: package.plannedRoute.segments)
        let point = package.plannedRoute.segments[0].points[4000]

        let projection = try #require(index.candidates(lat: point.lat, lng: point.lng, radiusM: 100).min {
            $0.offsetM < $1.offsetM
        })
        #expect(projection.offsetM < 1)
    }

    @Test func gridAndExhaustiveSearchAgree() throws {
        let package = try Self.tmb()
        let index = RouteIndex(segments: package.plannedRoute.segments)
        // Offset the query so it is genuinely off the line, not sitting on a
        // vertex where any method trivially agrees.
        let point = package.plannedRoute.segments[0].points[2500]
        let lat = point.lat + 0.0008
        let lng = point.lng + 0.0008

        let fromGrid = try #require(index.candidates(lat: lat, lng: lng, radiusM: 500).min { $0.offsetM < $1.offsetM })
        let exhaustive = try #require(index.nearestExhaustive(lat: lat, lng: lng))
        // The grid exists only to be faster, never to be different.
        #expect(abs(fromGrid.routeDistanceM - exhaustive.routeDistanceM) < 1)
    }

    @Test func gridStillFindsEdgesAtHighLatitude() {
        // Grid cells are sized in latitude degrees, but the same degree span
        // covers far fewer metres of longitude the further north you go. At 68°
        // (Lofoten — exactly the "future trails" case the plan asks for) a cell
        // is 187 m wide, so a radius converted to cells using the latitude
        // scale alone scans a box narrower than the radius asked for.
        //
        // The danger is not that the query is slow: it is that it returns a
        // *partial* candidate set without saying so, and the matcher then picks
        // the best of the wrong candidates.
        let points = (0..<20).map { TrackPoint(lat: 68.0 + Double($0) * 0.0005, lng: 15.0, ele: 10) }
        let index = RouteIndex(segments: [TripPackage.Segment(points: points)])

        // ~280 m due east of the line, inside the 300 m radius.
        let lat = 68.005
        let lng = 15.0 + 280.0 / (111_320.0 * cos(68.0 * .pi / 180))

        let fromGrid = index.candidates(lat: lat, lng: lng, radiusM: 300)
        let exhaustive = index.nearestExhaustive(lat: lat, lng: lng)

        #expect(exhaustive != nil)
        #expect(!fromGrid.isEmpty)
        if let best = fromGrid.min(by: { $0.offsetM < $1.offsetM }), let exhaustive {
            #expect(abs(best.routeDistanceM - exhaustive.routeDistanceM) < 1)
        }
    }

    @Test func doesNotHangOnAWorldSpanningEdge() throws {
        // An edge from +179.99 to -179.99 has a bounding box the width of the
        // planet and would be registered in 80,146 grid cells on its own. The
        // realistic cause is not a route round Fiji but one corrupt coordinate
        // in an imported GPX — and the symptom is the app hanging on trip open,
        // not a wrong position.
        let points = [
            TrackPoint(lat: 45.9, lng: 179.99, ele: 100),
            TrackPoint(lat: 45.9, lng: -179.99, ele: 100),
            TrackPoint(lat: 45.9, lng: -179.98, ele: 100)
        ]

        let started = Date()
        let index = RouteIndex(segments: [TripPackage.Segment(points: points)])
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < 1.0, "index build took \(elapsed)s")
        #expect(index.unindexedEdgeCount == 1)
        // Left out of the grid but not lost: the exhaustive path still sees it.
        #expect(index.nearestExhaustive(lat: 45.9, lng: -179.985) != nil)
    }

    @Test func normalRoutesHaveNothingLeftOutOfTheGrid() throws {
        let index = RouteIndex(segments: try Self.tmb().plannedRoute.segments)
        #expect(index.unindexedEdgeCount == 0)
    }

    @Test func convertsRouteDistanceBackToAPosition() throws {
        let index = RouteIndex(segments: try Self.tmb().plannedRoute.segments)
        let halfway = try #require(index.position(atRouteDistance: index.totalM / 2))
        let reprojected = try #require(index.nearestExhaustive(lat: halfway.lat, lng: halfway.lng))
        #expect(abs(reprojected.routeDistanceM - index.totalM / 2) < 5)
    }

    @Test func clampsRouteDistanceToTheEnds() throws {
        let index = RouteIndex(segments: try Self.tmb().plannedRoute.segments)
        #expect(index.position(atRouteDistance: -1000)?.routeDistanceM == 0)
        #expect(index.position(atRouteDistance: index.totalM + 1000)?.routeDistanceM == index.totalM)
    }

    // MARK: - Matching along the real route

    @Test func tracksAWalkAlongTheRealRoute() throws {
        let package = try Self.tmb()
        let index = RouteIndex(segments: package.plannedRoute.segments)
        var matcher = RouteMatcher(index: index)
        let points = package.plannedRoute.segments[0].points

        // Walk points 1000…1040, thirteen seconds apart.
        var lastRouteM = 0.0
        for (step, pointIndex) in (1000..<1040).enumerated() {
            let point = points[pointIndex]
            let match = matcher.match(Self.fix(step, point.lat, point.lng, at: Double(step) * 13))
            #expect(match.confidence != .lost)
            #expect(match.offsetM < 5)
            if step > 0 { #expect(match.routeDistanceM >= lastRouteM - 1) }
            lastRouteM = match.routeDistanceM
        }
    }

    @Test func staysOnTheNearSideOfALoopApproachingItself() throws {
        // The failure this whole class exists to prevent: on a closed loop the
        // line comes near itself, and a nearest-edge match can jump to the far
        // side — reporting tens of kilometres of progress in one fix.
        let package = try Self.tmb()
        let index = RouteIndex(segments: package.plannedRoute.segments)
        var matcher = RouteMatcher(index: index)
        let points = package.plannedRoute.segments[0].points

        matcher.seed(routeDistanceM: 2000, at: Date(timeIntervalSince1970: 1_700_000_000))
        var previous = 2000.0
        for (step, pointIndex) in stride(from: 100, to: 300, by: 10).enumerated() {
            let point = points[pointIndex]
            let match = matcher.match(Self.fix(step, point.lat, point.lng, at: Double(step + 1) * 13))
            // No physically impossible leap, whatever the geometry suggests.
            #expect(abs(match.routeDistanceM - previous) < 2000)
            previous = match.routeDistanceM
        }
    }

    // MARK: - Matching in the hard synthetic cases

    @Test func prefersThePlausibleBranchOnAnOutAndBack() {
        // Out-and-back: the return leg lies exactly on the outbound line, so
        // the two are spatially indistinguishable. Only elapsed time and the
        // previous position can separate them.
        let out = (0..<20).map { TrackPoint(lat: 45.9 + Double($0) * 0.0009, lng: 6.8, ele: 1000) }
        let back = (0..<20).map { TrackPoint(lat: 45.9 + Double(19 - $0) * 0.0009, lng: 6.8, ele: 1000) }
        let index = RouteIndex(segments: [TripPackage.Segment(points: out + back)])
        var matcher = RouteMatcher(index: index)

        // Walk out to the turnaround.
        for step in 0..<20 {
            _ = matcher.match(Self.fix(step, 45.9 + Double(step) * 0.0009, 6.8, at: Double(step) * 60))
        }
        let atTurn = try? #require(matcher.currentRouteDistanceM)
        #expect((atTurn ?? 0) > 1500)

        // Now walk back down the same line: progress must continue forward
        // along the route, not rewind along the outbound leg.
        var previous = matcher.currentRouteDistanceM ?? 0
        for step in 0..<10 {
            let match = matcher.match(
                Self.fix(100 + step, 45.9 + Double(18 - step) * 0.0009, 6.8, at: Double(20 + step) * 60)
            )
            #expect(match.routeDistanceM >= previous - 50)
            previous = match.routeDistanceM
        }
    }

    @Test func flagsAmbiguityOnAHairpinEvenWithAPerfectFix() {
        // A hairpin: 1500 m out, 8 m across, 1500 m back. Standing on the
        // outbound leg, the return leg is 8 m away but 1.5 km along the route —
        // genuinely ambiguous at GPS accuracy, and precisely what the loop
        // logic exists to catch.
        //
        // A multiplicative "rival within 1.5× the best" test gets this exactly
        // backwards: the better the fix, the smaller the best score, and the
        // harder ambiguity becomes to declare. At offset 0 no rival can ever
        // qualify.
        let eastDegrees = 1500.0 / (111_320.0 * cos(45.9 * .pi / 180))
        let northDegrees = 8.0 / 111_320.0
        let out = (0..<16).map {
            TrackPoint(lat: 45.9, lng: 6.8 + Double($0) * eastDegrees / 15, ele: 1000)
        }
        let back = (0..<16).map {
            TrackPoint(lat: 45.9 + northDegrees, lng: 6.8 + Double(15 - $0) * eastDegrees / 15, ele: 1000)
        }
        let index = RouteIndex(segments: [TripPackage.Segment(points: out + back)])
        var matcher = RouteMatcher(index: index)

        // Stand exactly on the outbound leg, halfway along.
        let match = matcher.match(Self.fix(1, 45.9, 6.8 + eastDegrees / 2, at: 0))
        #expect(match.offsetM < 2)
        #expect(match.confidence == .ambiguous)
    }

    @Test func flagsATeleportInsteadOfTrustingIt() {
        let index = Self.straightRoute()
        var matcher = RouteMatcher(index: index)

        _ = matcher.match(Self.fix(1, 45.9, 6.8, at: 0))
        // ~620 m in two seconds. Every candidate near the new fix is equally
        // implausible, so refusing to move is not an option — but the walker
        // may also have taken the Les Houches cable car. Follow it, flagged.
        let jumped = matcher.match(Self.fix(2, 45.9, 6.808, at: 2))
        #expect(jumped.confidence == .jumped)
        #expect(jumped.progressM > 500)

        // Once the position settles, confidence returns on its own.
        let settled = matcher.match(Self.fix(3, 45.9, 6.8081, at: 15))
        #expect(settled.confidence == .tracking)
    }

    @Test func aJumpDoesNotRaiseAnOffRouteAlert() {
        var monitor = OffRouteMonitor()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // Build up a genuine suspicion first.
        _ = monitor.update(match: Self.onRouteMatch(offsetM: 300, routeM: 1000), accuracyM: 8, at: start)

        // Then a teleport lands far from the line. One glitch must not be the
        // thing that finally trips the alert.
        let jumped = RouteMatcher.Match(
            routeDistanceM: 40_000, offsetM: 900, lat: 45.9, lng: 6.8,
            ele: nil, confidence: .jumped, progressM: 39_000
        )
        let update = monitor.update(match: jumped, accuracyM: 8, at: start.addingTimeInterval(20))
        #expect(!update.didEnterOffRoute)
        #expect(update.state != .offRoute)
    }

    @Test func ignoresFixesTooPoorToTrust() {
        let index = Self.straightRoute()
        var matcher = RouteMatcher(index: index)

        _ = matcher.match(Self.fix(1, 45.9, 6.8, at: 0))
        let before = matcher.currentRouteDistanceM

        // Core Location's "invalid fix" signal, and a merely useless one.
        #expect(matcher.match(Self.fix(2, 45.9, 6.803, at: 13, hAcc: -1)).confidence == .lost)
        #expect(matcher.match(Self.fix(3, 45.9, 6.803, at: 26, hAcc: 400)).confidence == .lost)
        // Neither moved the cursor.
        #expect(matcher.currentRouteDistanceM == before)
    }

    @Test func recoversAfterALongSignalGap() {
        let index = Self.straightRoute()
        var matcher = RouteMatcher(index: index)
        _ = matcher.match(Self.fix(1, 45.9, 6.8, at: 0))

        // Twenty minutes later, well along the line — impossible in 13 seconds
        // but entirely normal after a gap. The matcher has to place the walker
        // rather than refuse.
        let resumed = matcher.match(Self.fix(2, 45.9, 6.806, at: 1200))
        #expect(resumed.confidence != .lost)
        #expect(resumed.routeDistanceM > 300)
    }

    @Test func resetClearsHistory() {
        let index = Self.straightRoute()
        var matcher = RouteMatcher(index: index)
        _ = matcher.match(Self.fix(1, 45.9, 6.804, at: 0))
        #expect(matcher.currentRouteDistanceM != nil)
        matcher.reset()
        #expect(matcher.currentRouteDistanceM == nil)
    }

    // MARK: - Off-route

    static func onRouteMatch(offsetM: Double, routeM: Double = 0) -> RouteMatcher.Match {
        RouteMatcher.Match(
            routeDistanceM: routeM,
            offsetM: offsetM,
            lat: 45.9,
            lng: 6.8,
            ele: nil,
            confidence: .tracking,
            progressM: 0
        )
    }

    @Test func doesNotAlertOnASingleBadFix() {
        var monitor = OffRouteMonitor()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let update = monitor.update(match: Self.onRouteMatch(offsetM: 300), accuracyM: 8, at: start)
        // Suspected, not announced: one fix is never enough to claim a wrong turn.
        #expect(update.state == .suspect)
        #expect(!update.didEnterOffRoute)
    }

    @Test func alertsOnceTheDeviationPersistsInTimeAndDistance() {
        var monitor = OffRouteMonitor()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        _ = monitor.update(match: Self.onRouteMatch(offsetM: 300, routeM: 1000), accuracyM: 8, at: start)
        let later = monitor.update(
            match: Self.onRouteMatch(offsetM: 320, routeM: 1050),
            accuracyM: 8,
            at: start.addingTimeInterval(40)
        )
        #expect(later.state == .offRoute)
        #expect(later.didEnterOffRoute)
    }

    @Test func alertsOnlyOnceForOneDeparture() {
        var monitor = OffRouteMonitor()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = monitor.update(match: Self.onRouteMatch(offsetM: 300, routeM: 1000), accuracyM: 8, at: start)
        _ = monitor.update(
            match: Self.onRouteMatch(offsetM: 320, routeM: 1050),
            accuracyM: 8,
            at: start.addingTimeInterval(40)
        )
        // Still off-route, but a notification every fix is how an alert gets
        // ignored and then switched off.
        let again = monitor.update(
            match: Self.onRouteMatch(offsetM: 340, routeM: 1100),
            accuracyM: 8,
            at: start.addingTimeInterval(60)
        )
        #expect(again.state == .offRoute)
        #expect(!again.didEnterOffRoute)
    }

    @Test func doesNotAlertWhenTheFixIsTooVagueToBeSure() {
        var monitor = OffRouteMonitor()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // 90 m off with 60 m of error: consistent with standing on the path
        // under trees. Granting the error bar is what prevents the false alarm.
        _ = monitor.update(match: Self.onRouteMatch(offsetM: 90, routeM: 1000), accuracyM: 60, at: start)
        let later = monitor.update(
            match: Self.onRouteMatch(offsetM: 95, routeM: 1100),
            accuracyM: 60,
            at: start.addingTimeInterval(60)
        )
        #expect(later.state != .offRoute)
    }

    @Test func doesNotAlertForAStationaryPhoneDrifting() {
        var monitor = OffRouteMonitor()
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        // Ten minutes of a wandering fix while route distance barely moves —
        // a phone on a rock at a rest stop, not a wrong turn. The time
        // condition alone would have fired here; the distance one is why it
        // does not.
        var last = OffRouteMonitor.Update(state: .acquiring, didEnterOffRoute: false, didReturnToRoute: false)
        for step in 0..<20 {
            last = monitor.update(
                match: Self.onRouteMatch(offsetM: 200, routeM: 1000 + Double(step)),
                accuracyM: 8,
                at: start.addingTimeInterval(Double(step) * 30)
            )
        }
        #expect(last.state == .suspect)
        #expect(!last.didEnterOffRoute)
    }

    @Test func clearsOnlyWellInsideTheThreshold() {
        var monitor = OffRouteMonitor()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = monitor.update(match: Self.onRouteMatch(offsetM: 300, routeM: 1000), accuracyM: 8, at: start)
        _ = monitor.update(
            match: Self.onRouteMatch(offsetM: 320, routeM: 1050),
            accuracyM: 8,
            at: start.addingTimeInterval(40)
        )

        // 60 m sits in the band between exit (40) and enter (75): no decision,
        // which is what stops the alert flapping at the boundary.
        let inBand = monitor.update(
            match: Self.onRouteMatch(offsetM: 60, routeM: 1100),
            accuracyM: 5,
            at: start.addingTimeInterval(70)
        )
        #expect(inBand.state == .offRoute)

        let clear = monitor.update(
            match: Self.onRouteMatch(offsetM: 10, routeM: 1150),
            accuracyM: 5,
            at: start.addingTimeInterval(100)
        )
        #expect(clear.state == .onRoute)
        #expect(clear.didReturnToRoute)
    }

    @Test func reportsLostSignalInsteadOfAssumingOnRoute() {
        var monitor = OffRouteMonitor()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = monitor.update(match: Self.onRouteMatch(offsetM: 5), accuracyM: 8, at: start)

        let lost = RouteMatcher.Match(
            routeDistanceM: 0, offsetM: .infinity, lat: 45.9, lng: 6.8,
            ele: nil, confidence: .lost, progressM: 0
        )
        // Briefly: degraded.
        #expect(monitor.update(match: lost, accuracyM: -1, at: start.addingTimeInterval(30)).state == .degraded)
        // Sustained: explicit no-fix, never silence that reads as "fine".
        #expect(monitor.update(match: lost, accuracyM: -1, at: start.addingTimeInterval(300)).state == .noFix)
    }

    @Test func takesThresholdsFromTheTripPackage() throws {
        let package = try Self.tmb()
        let monitor = OffRouteMonitor(configuration: .init(navigationDefaults: package.navigationDefaults))
        // Per-trip, because a waymarked path and a faint traverse do not
        // deserve the same sensitivity.
        #expect(monitor.configuration.enterM == Double(package.navigationDefaults.offRouteEnterM))
        #expect(monitor.configuration.exitM == Double(package.navigationDefaults.offRouteExitM))
    }
}
