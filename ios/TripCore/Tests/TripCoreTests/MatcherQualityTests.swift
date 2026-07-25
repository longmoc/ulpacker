import Foundation
import Testing
@testable import TripCore

/// Quality guards on the real route.
///
/// The tests elsewhere check that specific situations are handled. These check
/// the opposite risk: that a fix for one situation has not made the matcher
/// noisy or slow everywhere else. Widening the ambiguity margin, in particular,
/// trades false negatives for false positives, and an ambiguity flag that fires
/// constantly is as useless as one that never fires.
struct MatcherQualityTests {
    static func tmbIndex() throws -> RouteIndex {
        RouteIndex(segments: try TripPackage.decode(
            from: TripPackageTests.fixtureData("tmb-ccw")
        ).plannedRoute.segments)
    }

    /// Walk the real route from `start`, one fix every 13 s, jittered off the
    /// line by a few metres the way a real receiver is.
    static func walk(
        index: RouteIndex,
        points: [TrackPoint],
        from start: Int,
        count: Int,
        jitterM: Double = 6
    ) -> [RouteMatcher.Match] {
        var matcher = RouteMatcher(index: index)
        var matches: [RouteMatcher.Match] = []
        var seed = 12345.0
        for step in 0..<count {
            let point = points[start + step]
            // Deterministic pseudo-jitter: repeatable across runs, unlike a
            // random generator, so a failure can actually be investigated.
            seed = (seed * 1103515245 + 12345).truncatingRemainder(dividingBy: 2147483648)
            let angle = seed / 2147483648 * 2 * .pi
            let dLat = cos(angle) * jitterM / 111_320
            let dLng = sin(angle) * jitterM / (111_320 * cos(point.lat * .pi / 180))
            matches.append(
                matcher.match(
                    ActivityPackage.Fix(
                        seq: step,
                        t: Date(timeIntervalSince1970: 1_700_000_000 + Double(step) * 13),
                        lat: point.lat + dLat,
                        lng: point.lng + dLng,
                        hAcc: 8
                    )
                )
            )
        }
        return matches
    }

    @Test func ambiguityStaysRareOnTheRealRoute() throws {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let index = RouteIndex(segments: package.plannedRoute.segments)
        let points = package.plannedRoute.segments[0].points

        // Four stretches spread around the loop, ~500 fixes in total.
        var matches: [RouteMatcher.Match] = []
        for start in [500, 2500, 5000, 7000] {
            matches += Self.walk(index: index, points: points, from: start, count: 125)
        }

        let ambiguous = matches.filter { $0.confidence == .ambiguous }.count
        let ratio = Double(ambiguous) / Double(matches.count)

        // The TMB does approach itself in places, so some ambiguity is correct.
        // Above roughly one fix in five it stops carrying information and the
        // UI would be permanently hedging.
        #expect(ratio < 0.2, "ambiguous on \(ambiguous)/\(matches.count) fixes")
    }

    @Test func neverLosesTrackWhileWalkingTheRealRoute() throws {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let index = RouteIndex(segments: package.plannedRoute.segments)
        let points = package.plannedRoute.segments[0].points
        let matches = Self.walk(index: index, points: points, from: 3000, count: 200)

        #expect(!matches.contains { $0.confidence == .lost })
        // A jump on a normal walk means the matcher moved somewhere no walker
        // could have reached — a correctness failure, not a GPS event.
        #expect(!matches.contains { $0.confidence == .jumped })
    }

    @Test func progressAlongTheRealRouteIsMonotonicAndPlausible() throws {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let index = RouteIndex(segments: package.plannedRoute.segments)
        let points = package.plannedRoute.segments[0].points
        let matches = Self.walk(index: index, points: points, from: 1500, count: 200)

        for match in matches.dropFirst() {
            // 13 s at any believable pace; jitter can make a step look slightly
            // backwards, but never by much.
            #expect(match.progressM > -30)
            #expect(match.progressM < 13 * 4.0)
        }
    }

    @Test func offRouteStaysQuietForSomeoneOnTheRealRoute() throws {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let index = RouteIndex(segments: package.plannedRoute.segments)
        let points = package.plannedRoute.segments[0].points

        // 25 m of jitter — heavy tree cover, but still on the path.
        let matches = Self.walk(index: index, points: points, from: 4000, count: 200, jitterM: 25)
        var monitor = OffRouteMonitor(configuration: .init(navigationDefaults: package.navigationDefaults))
        var alerts = 0
        for (step, match) in matches.enumerated() {
            let update = monitor.update(
                match: match,
                accuracyM: 25,
                at: Date(timeIntervalSince1970: 1_700_000_000 + Double(step) * 13)
            )
            if update.didEnterOffRoute { alerts += 1 }
        }

        // Not one false alarm in forty minutes of walking the line. This is the
        // number that decides whether the alert gets trusted or switched off.
        #expect(alerts == 0)
    }

    @Test func indexingTheRealRouteIsFastEnoughToDoAtTripOpen() throws {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let started = Date()
        let index = RouteIndex(segments: package.plannedRoute.segments)
        let elapsed = Date().timeIntervalSince(started)
        #expect(index.edges.count == 8560)
        // Built once when a trip opens; a second would be felt, 100 ms is not.
        #expect(elapsed < 1.0, "index build took \(elapsed)s")
    }

    @Test func aQueryReturnsRivalsWithoutReturningTheWholeRoute() throws {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let index = RouteIndex(segments: package.plannedRoute.segments)
        let point = package.plannedRoute.segments[0].points[4000]

        // This is what the grid is actually for: several candidates to score
        // against each other, not one nearest answer. Speed is a side effect —
        // measured at 0.01 ms against 0.05 ms for a full scan, both irrelevant
        // at one fix every thirteen seconds.
        let candidates = index.candidates(lat: point.lat, lng: point.lng, radiusM: 300)
        #expect(candidates.count > 1)
        #expect(candidates.count < 500, "grid returned \(candidates.count) of 8560 edges")
    }

    @Test func openingATripIsFastEnoughNotToBeFelt() throws {
        let data = try TripPackageTests.fixtureData("tmb-ccw")
        let started = Date()
        _ = try TripPackage.decode(from: data)
        let elapsed = Date().timeIntervalSince(started)

        // Decoding is ~8 ms; verifying the content hash costs the other ~40 ms
        // because it reparses the file through JSONSerialization. That second
        // parse is deliberate — the hash has to cover the bytes, including
        // fields this build does not model — and it happens once per trip open,
        // never per fix, so the cost buys integrity in the right place.
        #expect(elapsed < 0.5, "decode + verify took \(elapsed)s")
    }
}
