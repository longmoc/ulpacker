import Foundation
import Testing
@testable import TripCore

/// Three things that will happen on a real Tour du Mont Blanc.
///
/// Starting halfway along rather than at Les Houches; pausing for lunch,
/// forgetting, and resuming an hour and several kilometres later; and walking a
/// stretch that is not the planned line at all because a path was closed. None
/// of these is an error case — they are the normal shape of a nine-day walk,
/// and each one attacks the matcher's only real asset, which is knowing roughly
/// where the walker already was.
@MainActor
struct FieldCaseTests {
    static func package() throws -> TripPackage {
        try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
    }

    static func index(_ package: TripPackage) -> RouteIndex {
        RouteIndex(segments: package.plannedRoute.segments)
    }

    /// A point on the route at a given distance along it.
    static func onRoute(_ index: RouteIndex, at routeM: Double) throws -> (lat: Double, lng: Double) {
        let point = try #require(index.position(atRouteDistance: routeM))
        return (point.lat, point.lng)
    }

    static func fix(_ lat: Double, _ lng: Double, at seconds: Double, hAcc: Double = 8) -> ActivityPackage.Fix {
        .init(seq: 1, t: Date(timeIntervalSince1970: seconds), lat: lat, lng: lng, hAcc: hAcc)
    }

    // MARK: - 1. Starting in the middle

    @Test func picksUpFromTheMiddleOfTheRouteWithNoHistory() throws {
        let package = try Self.package()
        let index = Self.index(package)
        var matcher = RouteMatcher(index: index)

        // Day four, 70 km in. No prior at all — this is the first fix.
        let here = try Self.onRoute(index, at: 70_000)
        let match = matcher.match(Self.fix(here.lat, here.lng, at: 0))

        #expect(match.confidence != .lost)
        #expect(abs(match.routeDistanceM - 70_000) < 50)
        #expect(match.offsetM < 20)
    }

    @Test func aStartInTheMiddleThenWalksOnNormally() throws {
        let package = try Self.package()
        let index = Self.index(package)
        var matcher = RouteMatcher(index: index)

        var last = 0.0
        for step in 0...10 {
            let routeM = 70_000 + Double(step) * 100
            let here = try Self.onRoute(index, at: routeM)
            // 100 m every 80 s — a walking pace on a climb.
            let match = matcher.match(Self.fix(here.lat, here.lng, at: Double(step) * 80))
            #expect(match.confidence != .lost)
            #expect(abs(match.routeDistanceM - routeM) < 60)
            if step > 0 { #expect(match.routeDistanceM > last) }
            last = match.routeDistanceM
        }
    }

    // MARK: - 2. A pause that outlasts its intention

    @Test func resumingAfterALunchStopDoesNotLoseThePosition() throws {
        // Paused at 40 km, resumed 70 minutes later having walked 3 km on. The
        // walker is exactly where a walker would be; the matcher must land
        // there and not somewhere else on a route that passes nearby twice.
        let package = try Self.package()
        let index = Self.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 33_000, to: 40_000, startingAt: 0, stepM: 250, speedMPS: 1.2)
        try session.session.pause()
        session.session.resumeRecording()

        let resumeTime = session.clock + 70 * 60
        let here = try Self.onRoute(index, at: 43_000)
        let progress = try #require(
            try session.session.receive(
                lat: here.lat, lng: here.lng, at: Date(timeIntervalSince1970: resumeTime),
                horizontalAccuracyM: 8
            )
        )
        #expect(progress.confidence != .lost)
        #expect(abs(progress.routeDistanceM - 43_000) < 100)
    }

    @Test func resumingTheNextMorningStillLands() throws {
        // The overnight case: paused at a refuge, resumed fourteen hours later
        // a few hundred metres up the path. Elapsed time is now so large that
        // it constrains nothing, so this rests entirely on the fix itself.
        let package = try Self.package()
        let index = Self.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 55_000, to: 58_000, startingAt: 0, stepM: 250, speedMPS: 1.2)
        try session.session.pause()
        session.session.resumeRecording()

        let here = try Self.onRoute(index, at: 58_400)
        let progress = try #require(
            try session.session.receive(
                lat: here.lat, lng: here.lng,
                at: Date(timeIntervalSince1970: session.clock + 14 * 3600),
                horizontalAccuracyM: 8
            )
        )
        #expect(progress.confidence != .lost)
        #expect(abs(progress.routeDistanceM - 58_400) < 100)
    }

    // MARK: - 3. Walking something that is not the planned line

    @Test func aDetourIsRecordedInFullEvenWhileOffTheLine() throws {
        // The part that cannot be recovered later is the track itself. Whatever
        // the matcher makes of a closed path and a way round it, every fix must
        // reach the journal — a walk re-drawn from memory is not evidence.
        let package = try Self.package()
        let index = Self.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 20_000, to: 21_000, startingAt: 0, stepM: 250, speedMPS: 1.2)

        // Half a kilometre off the line for twenty minutes, then back.
        let away = try Self.onRoute(index, at: 21_000)
        for step in 1...10 {
            _ = try session.session.receive(
                lat: away.lat + 0.0045, lng: away.lng + Double(step) * 0.0002,
                at: Date(timeIntervalSince1970: session.clock + Double(step) * 120),
                horizontalAccuracyM: 8
            )
        }
        try session.session.flush()

        let fixes = try session.journal.readFixes()
        #expect(fixes.count == 15)
        // And the off-route stretch is in there as real coordinates, not as a
        // projection back onto the planned line.
        #expect(fixes.suffix(10).allSatisfy { $0.lat > away.lat + 0.004 })
    }

    @Test func rejoiningTheRouteAfterADetourPicksUpAgain() throws {
        let package = try Self.package()
        let index = Self.index(package)
        var matcher = RouteMatcher(index: index)

        let start = try Self.onRoute(index, at: 20_000)
        _ = matcher.match(Self.fix(start.lat, start.lng, at: 0))

        // Twenty minutes away from the line entirely.
        let away = try Self.onRoute(index, at: 20_500)
        for step in 1...10 {
            _ = matcher.match(Self.fix(away.lat + 0.0045, away.lng, at: Double(step) * 120))
        }

        // Back on the path, 1.5 km further along than where they left it.
        let back = try Self.onRoute(index, at: 22_000)
        let match = matcher.match(Self.fix(back.lat, back.lng, at: 1_400))
        #expect(match.confidence != .lost)
        #expect(abs(match.routeDistanceM - 22_000) < 100)
        #expect(match.offsetM < 20)
    }

    @Test func aLongAlternativeRouteAlertsOnceRatherThanRepeatedly() throws {
        // A closed path and an hour on a different valley track. One alert is
        // information; an alert every fix is something the walker turns off,
        // and then the one that matters is off too.
        let package = try Self.package()
        let index = Self.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 30_000, to: 30_500, startingAt: 0, stepM: 250, speedMPS: 1.2)

        let away = try Self.onRoute(index, at: 30_500)
        var alerts = 0
        for step in 1...30 {
            let progress = try session.session.receive(
                lat: away.lat + 0.006, lng: away.lng + Double(step) * 0.0003,
                at: Date(timeIntervalSince1970: session.clock + Double(step) * 120),
                horizontalAccuracyM: 8
            )
            if progress?.shouldAlertOffRoute == true { alerts += 1 }
        }
        #expect(alerts == 1)
    }
}

/// A session wired to a throwaway journal, with a helper that walks the route.
@MainActor
final class RecordingSessionHarness {
    let session: RecordingSession
    let index: RouteIndex
    private let root: URL
    private(set) var clock: Double = 0

    init(package: TripPackage, index: RouteIndex) throws {
        self.index = index
        root = URL.temporaryDirectory.appendingPathComponent("field-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        session = try RecordingSession.start(
            package: package,
            index: index,
            in: root,
            stageId: nil,
            nativeConfig: .init(
                desiredAccuracy: "best", distanceFilterM: 15, activityType: "fitness",
                pausesAutomatically: false, allowsBackgroundUpdates: true
            )
        )
    }

    /// Reopened from disk rather than reached through the session, which
    /// keeps its journal to itself — and reading the committed file is a
    /// stronger check anyway.
    var journal: ActivityJournal {
        get throws { try #require(try ActivityJournal.pendingSessions(in: root).first) }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Walk the planned line between two route distances at a given pace.
    func walk(from: Double, to: Double, startingAt: Double, stepM: Double, speedMPS: Double) throws {
        clock = startingAt
        var routeM = from
        while routeM <= to {
            if let point = index.position(atRouteDistance: routeM) {
                _ = try session.receive(
                    lat: point.lat, lng: point.lng,
                    at: Date(timeIntervalSince1970: clock), horizontalAccuracyM: 8
                )
            }
            routeM += stepM
            clock += stepM / speedMPS
        }
    }
}

/// The same three cases, at the one place on this route where they are hard.
///
/// The Tour du Mont Blanc is a loop: near Les Houches the first kilometre and
/// the last kilometre are the same ground. Anywhere else the nearest point on
/// the line is the answer; here there are two answers 163 km apart, and nothing
/// in the geometry says which.
@MainActor
struct LoopClosureTests {
    @Test func startingOnTheClosureIsReportedAsAmbiguous() throws {
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        var matcher = RouteMatcher(index: index)

        // Standing on the start line itself, which is also the finish line:
        // measured on this route the two branches are 0 m apart here, 12 m
        // apart 14 m along, and still within 90 m at 100 m along.
        let here = try FieldCaseTests.onRoute(index, at: 0)
        let match = matcher.match(FieldCaseTests.fix(here.lat, here.lng, at: 0))

        // It must not claim to be sure, and it must not announce that a walk
        // which has not begun is already finished.
        #expect(match.confidence == .ambiguous)
        #expect(match.routeDistanceM < 1_000, "reported \(match.routeDistanceM) m done at the start")
    }

    @Test func resumingOnTheClosureDoesNotSilentlyJumpToTheFinish() throws {
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        // Walked the first kilometre, paused, resumed half an hour later 400 m
        // further on. A walker cannot have covered 162 km over lunch.
        try session.walk(from: 0, to: 1_000, startingAt: 0, stepM: 200, speedMPS: 1.2)
        try session.session.pause()
        session.session.resumeRecording()

        let here = try FieldCaseTests.onRoute(index, at: 1_400)
        let progress = try #require(
            try session.session.receive(
                lat: here.lat, lng: here.lng,
                at: Date(timeIntervalSince1970: session.clock + 1_800),
                horizontalAccuracyM: 8
            )
        )
        #expect(progress.routeDistanceM < 5_000)
    }

    @Test func resumingBackAtTheStartLineDoesNotReadAsFinished() throws {
        // Walked 300 m, realised something was forgotten, walked back to the
        // car, resumed there half an hour later. The walker is standing on the
        // point that is both metre zero and metre 164,231, and the only thing
        // that can tell those apart is that they were at metre 300 a moment
        // ago — which is exactly the prior a resume used to throw away.
        let package = try FieldCaseTests.package()
        let index = FieldCaseTests.index(package)
        let session = try RecordingSessionHarness(package: package, index: index)

        try session.walk(from: 0, to: 300, startingAt: 0, stepM: 100, speedMPS: 1.2)
        try session.session.pause()
        session.session.resumeRecording()

        let here = try FieldCaseTests.onRoute(index, at: 0)
        let progress = try #require(
            try session.session.receive(
                lat: here.lat, lng: here.lng,
                at: Date(timeIntervalSince1970: session.clock + 1_800),
                horizontalAccuracyM: 8
            )
        )
        #expect(progress.routeDistanceM < 1_000, "reported \(progress.routeDistanceM) m done")
    }
}
