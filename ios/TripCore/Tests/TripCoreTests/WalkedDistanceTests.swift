import Foundation
import Testing
@testable import TripCore

/// Two numbers that were one number, and the rule that keeps the new one
/// honest.
///
/// Reported from a fifteen-minute walk: the route was cut short by looping
/// back early and "Done" still read the full length. It was reading progress
/// along the planned line, which was right, under a label that promised
/// distance walked, which was not.
@MainActor
struct WalkedDistanceTests {
    static func fix(
        _ seq: Int, _ lat: Double, _ lng: Double,
        at seconds: Double, speed: Double? = 1.3, hAcc: Double = 8
    ) -> ActivityPackage.Fix {
        .init(
            seq: seq, t: Date(timeIntervalSince1970: seconds),
            lat: lat, lng: lng, hAcc: hAcc, speed: speed
        )
    }

    // MARK: - The rule

    @Test func walkingCounts() {
        // ~111 m apart, at walking speed.
        let a = Self.fix(1, 45.9, 6.8, at: 0)
        let b = Self.fix(2, 45.901, 6.8, at: 80)
        #expect(abs(WalkedDistance.step(from: a, to: b) - 111) < 2)
    }

    @Test func aStationaryReceiverWalksNowhere() {
        // A phone on a refuge table. The fix jumped far enough to trip the
        // distance filter, but the receiver says the speed is nil-to-nothing —
        // and an overnight of that would add kilometres nobody walked.
        let a = Self.fix(1, 45.9, 6.8, at: 0, speed: 0.05)
        let b = Self.fix(2, 45.9002, 6.8, at: 60, speed: 0.05)
        #expect(WalkedDistance.step(from: a, to: b) == 0)
    }

    @Test func anUnknownSpeedIsNotTakenAsStandingStill() {
        // Some fixes carry no speed at all. "Unknown" must not be read as
        // "stationary", or a receiver having a bad minute erases real walking.
        let a = Self.fix(1, 45.9, 6.8, at: 0, speed: nil)
        let b = Self.fix(2, 45.901, 6.8, at: 80, speed: nil)
        #expect(WalkedDistance.step(from: a, to: b) > 100)
    }

    @Test func aStepShorterThanTheNoiseFloorIsDropped() {
        let a = Self.fix(1, 45.9, 6.8, at: 0)
        let b = Self.fix(2, 45.900008, 6.8, at: 10)  // ~0.9 m
        #expect(WalkedDistance.step(from: a, to: b) == 0)
    }

    @Test func poorFixesNeverReachTheTotal() {
        // 50 m is the accuracy ceiling; anything worse is evidence about
        // conditions, not about distance.
        let fixes = [
            Self.fix(1, 45.9, 6.8, at: 0),
            Self.fix(2, 45.901, 6.8, at: 80, hAcc: 400),
            Self.fix(3, 45.902, 6.8, at: 160)
        ]
        let total = WalkedDistance.total(of: fixes, maxAccuracyM: 50)
        // The bad middle fix is skipped, so this is the two good ones end to
        // end — about 222 m — rather than a detour through a wild reading.
        #expect(abs(total - 222) < 4)
    }

    // MARK: - What the walker sees

    @Test func cuttingTheCornerSeparatesWalkedFromRouteProgress() throws {
        // The reported case, in miniature: walk 1 km along the route, then jump
        // to a point 20 km further on. Route progress must follow the line;
        // walked distance must not pretend the missing 19 km happened.
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 0, to: 1_000, startingAt: 0, stepM: 200, speedMPS: 1.2)
        let far = try FieldCaseTests.onRoute(index, at: 21_000)
        let progress = try #require(
            try session.session.receive(
                lat: far.lat, lng: far.lng,
                at: Date(timeIntervalSince1970: session.clock + 7_200),
                horizontalAccuracyM: 8, speed: 1.3
            )
        )

        #expect(abs(progress.routeDistanceM - 21_000) < 200)
        // The straight hop is one step and it is long, so it does land in the
        // total — what matters is that walked and route progress are now
        // different numbers rather than the same one wearing two labels.
        #expect(progress.walkedM < progress.routeDistanceM)
    }

    @Test func theMapIsGivenTheFixAndNotTheProjection() throws {
        // 300 m off the line: close enough that the matcher still reports
        // progress, far enough that drawing the projection would put the
        // walker on a path they are nowhere near.
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        let onLine = try FieldCaseTests.onRoute(index, at: 5_000)
        let strayed = (lat: onLine.lat + 0.0027, lng: onLine.lng)
        let progress = try #require(
            try session.session.receive(
                lat: strayed.lat, lng: strayed.lng,
                at: Date(timeIntervalSince1970: 0), horizontalAccuracyM: 8, speed: 1.3
            )
        )

        #expect(progress.fixLat == strayed.lat)
        #expect(progress.fixLng == strayed.lng)
        // And the snapped position is still there for the numbers that need it.
        #expect(progress.lat != progress.fixLat)
        #expect(progress.offsetM > 200)
    }

    @Test func theCourseIsCarriedWhileMovingAndWithheldWhenStill() throws {
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)
        let here = try FieldCaseTests.onRoute(index, at: 5_000)

        let walking = try #require(
            try session.session.receive(
                lat: here.lat, lng: here.lng, at: Date(timeIntervalSince1970: 0),
                horizontalAccuracyM: 8, speed: 1.4, bearing: 214
            )
        )
        #expect(walking.courseDegrees == 214)

        // Standing still the receiver's course means nothing, whatever number
        // it happens to be holding.
        let ahead = try FieldCaseTests.onRoute(index, at: 5_200)
        let still = try #require(
            try session.session.receive(
                lat: ahead.lat, lng: ahead.lng, at: Date(timeIntervalSince1970: 200),
                horizontalAccuracyM: 8, speed: 0.05, bearing: 214
            )
        )
        #expect(still.courseDegrees == nil)
    }

    @Test func theSavedWalkAgreesWithTheLiveReadout() throws {
        // The two used different sums until now — the live one did not exist.
        // They must not drift apart.
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 0, to: 3_000, startingAt: 0, stepM: 200, speedMPS: 1.2)
        let live = try #require(session.session.progress).walkedM
        let saved = try session.session.finish()

        #expect(abs(Double(saved.stats.distanceM) - live) < 1)
    }
}
