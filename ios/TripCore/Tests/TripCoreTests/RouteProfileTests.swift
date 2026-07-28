import Foundation
import Testing
@testable import TripCore

/// Distance, climb and time for a stretch of the route.
///
/// The load-bearing test here is the first one: every walking day in the TMB
/// fixture carries ascent and descent figures the *web planner* computed, and
/// this suite recomputes them from the geometry in Swift. If the two methods
/// drift, a walker gets one number on the laptop and another on the phone with
/// nothing to say which is right — so the disagreement is made to fail here
/// instead.
struct RouteProfileTests {
    static func package(_ name: String) throws -> TripPackage {
        try JSONDecoder().decode(
            TripPackage.self, from: try TripPackageTests.fixtureData(name)
        )
    }

    /// Build a package with the given elevations, one metre apart along a line.
    static func package(elevations: [Double?]) throws -> TripPackage {
        let points = elevations.enumerated().map { index, ele -> String in
            // ~1.11 m per 0.00001° of latitude: close enough that a hundred
            // points make a hundred-metre walk.
            let lat = 45.9 + Double(index) * 0.00001
            return ele.map { "[\(lat),6.8,\($0)]" } ?? "[\(lat),6.8,null]"
        }.joined(separator: ",")

        let json = """
        {"format":"ulpacker-trip-package","schemaVersion":1,"hashAlgorithm":"fnv1a64",
         "tripId":"t","revision":1,"publishedAt":"2026-01-01T00:00:00.000Z",
         "trip":{"name":"T","description":"","startName":"","finishName":"","loop":false,
                 "startDayNumber":1},
         "plannedRoute":{"segments":[{"points":[\(points)]}],
           "stats":{"distanceM":1,"ascentM":null,"descentM":null,"minEle":null,"maxEle":null,
                    "elevationCoverage":1,"pointCount":\(elevations.count),"segmentCount":1}},
         "checkpoints":[],"itinerary":[],"extraDays":[],
         "navigationDefaults":{"offRouteEnterM":75,"offRouteExitM":40},"contentHash":"x"}
        """
        return try JSONDecoder().decode(TripPackage.self, from: Data(json.utf8))
    }

    // MARK: - Agreement with the planner

    @Test func climbOverEveryWalkingDayMatchesThePlanner() throws {
        let package = try Self.package("tmb-ccw")
        let profile = RouteProfile(package: package)

        #expect(package.itinerary.count == 9)
        for day in package.itinerary {
            let leg = profile.leg(
                fromRouteM: Double(day.startRouteM), toRouteM: Double(day.endRouteM)
            )
            let ascent = try #require(leg.ascentM)
            let descent = try #require(leg.descentM)
            // Two metres of tolerance, and it cannot be tightened from a
            // package alone: the day boundaries travel as whole metres, so the
            // range being measured here is the planner's to within half a
            // metre at each end. On a steep slope that half metre moves one
            // sample in or out of the run and shifts the total by a metre or
            // so. Six of the nine days land within half a metre regardless;
            // the worst is 1.9 m out of 1888.
            #expect(abs(ascent - Double(try #require(day.ascentM))) <= 2,
                    "day \(day.index) ascent \(ascent)")
            #expect(abs(descent - Double(try #require(day.descentM))) <= 2,
                    "day \(day.index) descent \(descent)")
        }
    }

    @Test func distanceOverAWalkingDayMatchesThePlanner() throws {
        let package = try Self.package("tmb-ccw")
        let profile = RouteProfile(package: package)
        for day in package.itinerary {
            let leg = profile.leg(
                fromRouteM: Double(day.startRouteM), toRouteM: Double(day.endRouteM)
            )
            #expect(abs(leg.distanceM - Double(day.distanceM)) <= 1)
        }
    }

    // MARK: - Direction

    @Test func walkingBackToAStopSwapsClimbForDescent() throws {
        let package = try Self.package("tmb-ccw")
        let profile = RouteProfile(package: package)
        let day = try #require(package.itinerary.first)

        let forward = profile.leg(
            fromRouteM: Double(day.startRouteM), toRouteM: Double(day.endRouteM)
        )
        let back = profile.leg(
            fromRouteM: Double(day.endRouteM), toRouteM: Double(day.startRouteM)
        )

        #expect(back.isBehind)
        #expect(!forward.isBehind)
        #expect(back.distanceM == forward.distanceM)
        #expect(back.ascentM == forward.descentM)
        #expect(back.descentM == forward.ascentM)
        // Descending what you climbed is quicker, so the two legs are not the
        // same walk even though they cover the same ground.
        #expect(try #require(back.duration) < #require(forward.duration))
    }

    // MARK: - Smoothing

    @Test func metreScaleNoiseDoesNotInventClimb() throws {
        // A dead-flat 200 m walk recorded by a device that wobbles a metre
        // either way. Summed raw that is 100 m of ascent invented out of
        // nothing, which is what the moving average is there to suppress — it
        // damps the wobble to a fifth of its amplitude rather than erasing it,
        // so about 20 m survives. Not perfect; the difference between a flat
        // walk reading 100 m of climb and one reading 20 m is the difference
        // between a useless number and a usable one.
        let noisy = (0..<200).map { Double($0 % 2 == 0 ? 1000 : 1001) as Double? }
        let profile = RouteProfile(package: try Self.package(elevations: noisy))
        let leg = profile.leg(fromRouteM: 0, toRouteM: profile.totalM)
        #expect(try #require(leg.ascentM) < 25)
    }

    @Test func realClimbSurvivesSmoothing() throws {
        // 100 points climbing 5 m each: 495 m of raw ascent. Smoothing keeps
        // all but 10 m of it — the moving average has only half a window to
        // work with at each end of a run, which pulls the first and last
        // values one step towards the middle. Real climb survives; the loss is
        // a fixed edge effect, not a fraction of the total.
        let climbing = (0..<100).map { Double(1000 + $0 * 5) as Double? }
        let profile = RouteProfile(package: try Self.package(elevations: climbing))
        let leg = profile.leg(fromRouteM: 0, toRouteM: profile.totalM)
        #expect(abs(try #require(leg.ascentM) - 485) < 1)
        #expect(try #require(leg.descentM) == 0)
    }

    @Test func routeWithoutElevationReportsNothingRatherThanFlat() throws {
        let profile = RouteProfile(package: try Self.package(elevations: [nil, nil, nil, nil]))
        let leg = profile.leg(fromRouteM: 0, toRouteM: profile.totalM)
        // Nil, not zero: "we do not know" and "it is flat" are different
        // answers, and only one of them should be shown as a flat walk.
        #expect(leg.ascentM == nil)
        #expect(leg.descentM == nil)
        #expect(leg.duration != nil)
    }

    @Test func climbStopsAtAGapInTheElevationData() throws {
        // 1000 → 1050, a hole, then 1200 → 1250. The 150 m step across the hole
        // is not walking anybody did; only the two known runs count.
        var elevations: [Double?] = (0..<11).map { Double(1000 + $0 * 5) }
        elevations.append(nil)
        elevations.append(contentsOf: (0..<11).map { Double(1200 + $0 * 5) })
        let profile = RouteProfile(package: try Self.package(elevations: elevations))
        let leg = profile.leg(fromRouteM: 0, toRouteM: profile.totalM)
        #expect(try #require(leg.ascentM) < 110)
    }

    // MARK: - Pace

    @Test func paceFollowsTheAlpineClubMethod() {
        // 12 km, 900 m up, 600 m down. Horizontal 3.0 h; vertical 2.25 + 0.75
        // = 3.0 h. Larger plus half the smaller: 3.0 + 1.5 = 4.5 h.
        let duration = RouteProfile.Pace.duration(distanceM: 12_000, ascentM: 900, descentM: 600)
        #expect(abs(duration - 4.5 * 3600) < 1)
    }

    @Test func aFlatWalkIsJustDistanceOverSpeed() {
        let duration = RouteProfile.Pace.duration(distanceM: 8_000, ascentM: 0, descentM: 0)
        #expect(abs(duration - 2 * 3600) < 1)
    }

    @Test func theCiceroneStageTimeIsReproduced() {
        // Cicerone's first Tour du Mont Blanc stage — Les Houches to Les
        // Contamines over the Col de Tricot — is 17 km with 1150 m of ascent
        // and 1210 m of descent, and the book calls it 6 h 30. This is the
        // check that keeps the constants honest against a published time for
        // the exact route the app is for.
        let hours = RouteProfile.Pace.duration(
            distanceM: 17_000, ascentM: 1150, descentM: 1210
        ) / 3600
        #expect(abs(hours - 6.5) < 0.2)
    }

    @Test func aTourDuMontBlancDayLandsInTheGuidebookRange() throws {
        // The fixture's first day is a longer variant of that stage: 18.9 km
        // with 1530 m of climb. Anything outside 6.5 to 8.5 hours would be
        // actively misleading on the one route this app was built for.
        let package = try Self.package("tmb-ccw")
        let profile = RouteProfile(package: package)
        let day = try #require(package.itinerary.first)
        let hours = profile.leg(
            fromRouteM: Double(day.startRouteM), toRouteM: Double(day.endRouteM)
        ).duration.map { $0 / 3600 }
        #expect(try #require(hours) > 6.5)
        #expect(try #require(hours) < 8.5)
    }
}

/// Framing one stretch of the route on a map.
struct RouteBoundsTests {
    @Test func aDayIsFramedInsideTheWholeTrip() throws {
        let package = try RouteProfileTests.package("tmb-ccw")
        let profile = RouteProfile(package: package)
        let whole = try #require(profile.bounds(fromRouteM: 0, toRouteM: profile.totalM))
        let day = try #require(package.itinerary.first)
        let dayBounds = try #require(
            profile.bounds(fromRouteM: Double(day.startRouteM), toRouteM: Double(day.endRouteM))
        )

        // Inside the trip's box, and meaningfully smaller than it — a day that
        // framed the whole Mont Blanc massif would be no use as a preview.
        #expect(dayBounds.minLat >= whole.minLat && dayBounds.maxLat <= whole.maxLat)
        #expect(dayBounds.minLng >= whole.minLng && dayBounds.maxLng <= whole.maxLng)
        let dayArea = (dayBounds.maxLat - dayBounds.minLat) * (dayBounds.maxLng - dayBounds.minLng)
        let wholeArea = (whole.maxLat - whole.minLat) * (whole.maxLng - whole.minLng)
        #expect(dayArea < wholeArea / 4)
    }

    @Test func anEmptyStretchHasNoBounds() throws {
        let package = try RouteProfileTests.package("tmb-ccw")
        let profile = RouteProfile(package: package)
        #expect(profile.bounds(fromRouteM: profile.totalM + 1_000, toRouteM: profile.totalM + 2_000) == nil)
    }
}

/// Reading a single point off the profile.
struct ProfilePointTests {
    @Test func elevationFollowsTheRoute() throws {
        let package = try RouteProfileTests.package("tmb-ccw")
        let profile = RouteProfile(package: package)
        let low = try #require(profile.elevation(atRouteM: 0))
        let stats = package.plannedRoute.stats
        #expect(low >= Double(try #require(stats.minEle)) - 1)
        #expect(low <= Double(try #require(stats.maxEle)) + 1)
    }

    @Test func gradientIsMeasuredOverAWindowNotBetweenNeighbours() throws {
        // Points on this route are 19 m apart, where a single pair is mostly
        // the elevation data's own noise. Over a window the figure has to stay
        // inside what a person can actually walk up.
        let package = try RouteProfileTests.package("tmb-ccw")
        let profile = RouteProfile(package: package)
        let samples = stride(from: 1_000.0, to: 160_000.0, by: 997.0)
        let gradients = samples.compactMap { profile.gradient(atRouteM: $0) }
        #expect(gradients.count > 100)
        #expect(gradients.allSatisfy { abs($0) < 70 })
    }

    @Test func aClimbReadsPositiveAndADescentNegative() throws {
        let package = try RouteProfileTests.package("tmb-ccw")
        let profile = RouteProfile(package: package)
        // Day one leaves Les Houches climbing almost continuously.
        let up = try #require(profile.gradient(atRouteM: 3_000))
        #expect(up > 0)
    }
}
