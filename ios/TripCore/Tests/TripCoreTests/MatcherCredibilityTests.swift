import Foundation
import Testing
@testable import TripCore

/// The matcher must be able to say "not here".
///
/// Every fix has a nearest point on the route, including a fix on another
/// continent, and a matcher that always answers will always answer confidently.
/// Reported from the simulator: start the app anywhere outside the Alps and it
/// showed the walker 28 km along the Tour du Mont Blanc, on the line, with 136
/// km left — because that genuinely is the closest the route comes.
struct MatcherCredibilityTests {
    static func matcher() throws -> (RouteMatcher, TripPackage) {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let index = RouteIndex(segments: package.plannedRoute.segments)
        return (RouteMatcher(index: index), package)
    }

    static func fix(_ lat: Double, _ lng: Double, at seconds: Double = 0) -> ActivityPackage.Fix {
        .init(seq: 1, t: Date(timeIntervalSince1970: seconds), lat: lat, lng: lng, hAcc: 5)
    }

    @Test func aFixNowhereNearTheRouteIsLostRatherThanProjected() throws {
        let (matcher, _) = try Self.matcher()
        // Cupertino, which is where a simulator sits until told otherwise.
        var matcher2 = matcher
        let match = matcher2.match(Self.fix(37.3349, -122.0090))
        #expect(match.confidence == .lost)
        // And the position it reports is the fix itself, not a point on a
        // mountain the walker has never seen.
        #expect(abs(match.lat - 37.3349) < 1e-6)
        #expect(abs(match.lng + 122.0090) < 1e-6)
    }

    @Test func doesNotCreditDistanceForStandingSomewhereElse() throws {
        let (matcher, _) = try Self.matcher()
        var matcher2 = matcher
        let match = matcher2.match(Self.fix(51.5074, -0.1278))  // London
        // Route distance stays where it was — nought, for a walk not started —
        // rather than the 28 km that the nearest projection would have claimed.
        #expect(match.routeDistanceM == 0)
        #expect(match.confidence == .lost)
    }

    @Test func stillMatchesAWalkerActuallyOnTheRoute() throws {
        let (matcher, package) = try Self.matcher()
        var matcher2 = matcher
        let start = try #require(package.plannedRoute.segments.first?.points.first)
        let match = matcher2.match(Self.fix(start.lat, start.lng))
        // Ambiguous, not tracking: this is a loop, so standing at Les Houches
        // is standing at both ends of it at once. What matters here is that it
        // is not lost and the walker is on the line.
        #expect(match.confidence != .lost)
        #expect(match.offsetM < 5)
    }

    // MARK: - The boundary itself

    /// A straight west-east line, so "how far off" is a number the test sets
    /// rather than one the terrain decides. On the real Tour du Mont Blanc the
    /// route doubles back on itself constantly — a walker a kilometre from one
    /// leg is a few hundred metres from another — which makes it useless for
    /// exercising a distance limit.
    static func straightRoute() throws -> RouteMatcher {
        let points = (0...50).map { step in
            "[45.9,\(6.80 + Double(step) * 0.001),1000]"
        }.joined(separator: ",")
        let json = """
        {"format":"ulpacker-trip-package","schemaVersion":1,"hashAlgorithm":"fnv1a64",
         "tripId":"t","revision":1,"publishedAt":"2026-01-01T00:00:00.000Z",
         "trip":{"name":"T","description":"","startName":"","finishName":"","loop":false,
                 "startDayNumber":1},
         "plannedRoute":{"segments":[{"points":[\(points)]}],
           "stats":{"distanceM":3900,"ascentM":0,"descentM":0,"minEle":1000,"maxEle":1000,
                    "elevationCoverage":1,"pointCount":51,"segmentCount":1}},
         "checkpoints":[],"itinerary":[],"extraDays":[],
         "navigationDefaults":{"offRouteEnterM":75,"offRouteExitM":40},"contentHash":"x"}
        """
        let package = try JSONDecoder().decode(TripPackage.self, from: Data(json.utf8))
        return RouteMatcher(index: RouteIndex(segments: package.plannedRoute.segments))
    }

    @Test func aRealDetourIsStillFollowed() throws {
        // A kilometre off the line: a wrong turn, a variant, a bail-out down a
        // valley. All of these are still this walk, and the position has to
        // survive them — which is why the limit sits well beyond here.
        var matcher = try Self.straightRoute()
        let match = matcher.match(Self.fix(45.9 + 0.009, 6.825))
        #expect(match.confidence != .lost)
        #expect(match.offsetM > 900 && match.offsetM < 1_100)
    }

    @Test func pastTheLimitTheRouteStopsAnswering() throws {
        // Five kilometres off. There is still a nearest point on the line, and
        // reporting it would be the confident, useless answer.
        var matcher = try Self.straightRoute()
        let match = matcher.match(Self.fix(45.9 + 0.045, 6.825))
        #expect(match.confidence == .lost)
        #expect(match.routeDistanceM == 0)
    }

}
