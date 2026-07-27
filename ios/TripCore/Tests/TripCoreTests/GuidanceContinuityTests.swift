import Foundation
import Testing
@testable import TripCore

/// Does the app still guide the rest of the walk?
///
/// Matching a position is only the first half. What the walker actually uses is
/// what follows from it — the next stop and how far it is, how much route is
/// left, which way the line runs from here — and all of that is derived from a
/// single number. So the question "does navigation still work after a pause"
/// is really "does that number keep meaning what it says", asked of three
/// situations where the walker arrives without the app having watched them get
/// there: starting halfway along, resuming after a pause, and rejoining the
/// line after walking something else.
@MainActor
struct GuidanceContinuityTests {
    /// Everything the walking screen shows, from one progress update.
    static func check(
        _ progress: RecordingSession.Progress?,
        expectedRouteM: Double,
        package: TripPackage,
        totalM: Double,
        tolerance: Double = 100
    ) throws {
        let progress = try #require(progress)
        #expect(abs(progress.routeDistanceM - expectedRouteM) < tolerance)

        // How much walk is left.
        #expect(abs(progress.remainingM - (totalM - progress.routeDistanceM)) < 1)

        // The next stop is genuinely the next one ahead, not one already passed.
        let next = try #require(progress.nextCheckpoint)
        #expect(Double(next.routeDistanceM) > progress.routeDistanceM)
        let skipped = package.checkpoints.filter {
            Double($0.routeDistanceM) > progress.routeDistanceM
                && $0.routeDistanceM < next.routeDistanceM
        }
        #expect(skipped.isEmpty, "offered \(next.name) with \(skipped.count) nearer stops ahead")

        // And how far it is, which is the number the walker plans the
        // afternoon around.
        let distance = try #require(progress.distanceToNextCheckpointM)
        #expect(distance > 0)
        #expect(abs(distance - (Double(next.routeDistanceM) - progress.routeDistanceM)) < 1)
    }

    // MARK: - Starting halfway along

    @Test func guidesTheRestOfTheRouteFromAMidTrailStart() throws {
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        // Straight onto day four with no history at all.
        let here = try FieldCaseTests.onRoute(index, at: 70_000)
        let progress = try session.session.receive(
            lat: here.lat, lng: here.lng, at: Date(timeIntervalSince1970: 0),
            horizontalAccuracyM: 8
        )
        try Self.check(progress, expectedRouteM: 70_000, package: package, totalM: index.totalM)

        // And it keeps guiding as they walk on, with the next stop advancing
        // past each one reached rather than sticking.
        var seen: Set<String> = []
        for step in 1...40 {
            let point = try FieldCaseTests.onRoute(index, at: 70_000 + Double(step) * 200)
            let update = try session.session.receive(
                lat: point.lat, lng: point.lng,
                at: Date(timeIntervalSince1970: Double(step) * 160), horizontalAccuracyM: 8
            )
            if let name = update?.nextCheckpoint?.name { seen.insert(name) }
        }
        #expect(seen.count >= 2, "the next stop never changed over 8 km")
    }

    // MARK: - After a pause

    @Test func guidanceResumesAfterAPause() throws {
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 33_000, to: 40_000, startingAt: 0, stepM: 250, speedMPS: 1.2)
        try session.session.pause()
        session.session.resumeRecording()

        let here = try FieldCaseTests.onRoute(index, at: 43_000)
        let progress = try session.session.receive(
            lat: here.lat, lng: here.lng,
            at: Date(timeIntervalSince1970: session.clock + 70 * 60), horizontalAccuracyM: 8
        )
        try Self.check(progress, expectedRouteM: 43_000, package: package, totalM: index.totalM)
    }

    @Test func aPausedSessionGuidesNobodyUntilItResumes() throws {
        // The other half of the contract: while paused there is no position, so
        // there is nothing to guide with and the screen must not pretend
        // otherwise by holding the last one.
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 10_000, to: 10_500, startingAt: 0, stepM: 250, speedMPS: 1.2)
        try session.session.pause()

        let here = try FieldCaseTests.onRoute(index, at: 11_000)
        let progress = try session.session.receive(
            lat: here.lat, lng: here.lng,
            at: Date(timeIntervalSince1970: session.clock + 600), horizontalAccuracyM: 8
        )
        #expect(progress == nil)
    }

    // MARK: - After walking something else

    @Test func guidanceResumesOnRejoiningAfterADetour() throws {
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 20_000, to: 21_000, startingAt: 0, stepM: 250, speedMPS: 1.2)

        // Forty minutes on a different path, half a kilometre off the line.
        let away = try FieldCaseTests.onRoute(index, at: 21_000)
        for step in 1...20 {
            _ = try session.session.receive(
                lat: away.lat + 0.0045, lng: away.lng + Double(step) * 0.0003,
                at: Date(timeIntervalSince1970: session.clock + Double(step) * 120),
                horizontalAccuracyM: 8
            )
        }

        // Back on the line, 2 km further along than where they left it.
        let back = try FieldCaseTests.onRoute(index, at: 23_000)
        let progress = try session.session.receive(
            lat: back.lat, lng: back.lng,
            at: Date(timeIntervalSince1970: session.clock + 2_600), horizontalAccuracyM: 8
        )
        try Self.check(progress, expectedRouteM: 23_000, package: package, totalM: index.totalM)

        // The stops inside the skipped stretch are behind now, and must not be
        // offered as though they were still to come.
        let next = try #require(progress?.nextCheckpoint)
        #expect(Double(next.routeDistanceM) > 23_000)
    }

    @Test func theLineStillHasADirectionFromWhereverTheWalkerRejoins() throws {
        // The arrow on the map is a bearing taken along the route ahead of the
        // matched position. It is the one piece of guidance that would fail
        // silently — pointing somewhere plausible and wrong — so it is checked
        // from a position the app never watched the walker reach.
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)

        for routeM in [0.0, 23_000, 70_000, 140_000] {
            let here = try #require(index.position(atRouteDistance: routeM))
            let ahead = try #require(
                index.position(atRouteDistance: min(index.totalM, routeM + 60))
            )
            let bearing = TripPackage.bearing(
                fromLat: here.lat, fromLng: here.lng, toLat: ahead.lat, toLng: ahead.lng
            )
            #expect(bearing >= 0 && bearing < 360)

            // Taken over real ground, not between two copies of the same point.
            // Two identical coordinates give a bearing of 0 — due north,
            // confidently, everywhere — which is the way this fails silently.
            let separation = ActivityJournal.haversine(
                here.lat, here.lng, ahead.lat, ahead.lng
            )
            #expect(separation > 30, "look-ahead collapsed to \(separation) m at \(routeM)")
        }
    }
}
