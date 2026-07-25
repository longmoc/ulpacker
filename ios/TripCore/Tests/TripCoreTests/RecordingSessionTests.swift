import Foundation
import Testing
@testable import TripCore

/// End-to-end recording tests, driven by synthetic fixes along the real route.
///
/// These cover the seams between the pieces — buffering versus crash safety,
/// pause versus resume, what survives a kill — which is where the bugs live
/// once the individual parts are known to work.
@MainActor
struct RecordingSessionTests {
    static func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ulpacker-session-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static let nativeConfig = ActivityPackage.NativeConfig(
        desiredAccuracy: "kCLLocationAccuracyBest",
        distanceFilterM: 15,
        activityType: "fitness",
        pausesAutomatically: false,
        allowsBackgroundUpdates: true
    )

    static func tmb() throws -> (TripPackage, RouteIndex) {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        return (package, RouteIndex(segments: package.plannedRoute.segments))
    }

    static func start(
        root: URL,
        package: TripPackage,
        index: RouteIndex,
        configuration: RecordingSession.Configuration = .init()
    ) throws -> RecordingSession {
        try RecordingSession.start(
            package: package,
            index: index,
            in: root,
            activityId: "act-test",
            stageId: "day-1",
            nativeConfig: nativeConfig,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            configuration: configuration
        )
    }

    /// Feed `count` points of the real route into the session.
    @discardableResult
    static func walk(
        _ session: RecordingSession,
        points: [TrackPoint],
        from start: Int,
        count: Int,
        hAcc: Double = 8,
        startingAt offset: Double = 0
    ) throws -> [RecordingSession.Progress] {
        var results: [RecordingSession.Progress] = []
        for step in 0..<count {
            let point = points[start + step]
            if let progress = try session.receive(
                lat: point.lat,
                lng: point.lng,
                at: Date(timeIntervalSince1970: 1_700_000_000 + offset + Double(step) * 13),
                horizontalAccuracyM: hAcc
            ) {
                results.append(progress)
            }
        }
        return results
    }

    // MARK: - Recording

    @Test func reportsProgressAlongTheRealRoute() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(root: root, package: package, index: index)
        let points = package.plannedRoute.segments[0].points

        let progress = try Self.walk(session, points: points, from: 2000, count: 30)
        let last = try #require(progress.last)

        #expect(last.fixCount == 30)
        #expect(last.rejectedFixCount == 0)
        #expect(last.offRouteState == .onRoute)
        #expect(last.routeDistanceM > 0)
        #expect(last.remainingM > 0)
        #expect(abs(last.routeDistanceM + last.remainingM - index.totalM) < 1)
    }

    @Test func pointsAtTheNextCheckpointAhead() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(root: root, package: package, index: index)
        let points = package.plannedRoute.segments[0].points

        let progress = try Self.walk(session, points: points, from: 1000, count: 20)
        let last = try #require(progress.last)
        let next = try #require(last.nextCheckpoint)

        // Ahead, never behind — this drives "2.3 km to the refuge".
        #expect(Double(next.routeDistanceM) > last.routeDistanceM)
        #expect(try #require(last.distanceToNextCheckpointM) > 0)
    }

    @Test func countsBadFixesWithoutLettingThemMoveThePosition() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(root: root, package: package, index: index)
        let points = package.plannedRoute.segments[0].points

        try Self.walk(session, points: points, from: 3000, count: 5)
        let before = try #require(session.progress).routeDistanceM

        // A useless fix 2 km away — the classic under-canopy artefact.
        let progress = try #require(try session.receive(
            lat: points[3005].lat + 0.02,
            lng: points[3005].lng,
            at: Date(timeIntervalSince1970: 1_700_000_100),
            horizontalAccuracyM: 400
        ))

        #expect(progress.confidence == .lost)
        #expect(progress.rejectedFixCount == 1)
        #expect(progress.routeDistanceM == before)
        // Still recorded: a rejected fix is evidence about the conditions.
        #expect(progress.fixCount == 6)
    }

    // MARK: - Durability

    @Test func bufferedFixesReachDiskOnSchedule() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(
            root: root, package: package, index: index,
            configuration: .init(flushEveryFixes: 5, flushInterval: 3600)
        )
        let points = package.plannedRoute.segments[0].points

        try Self.walk(session, points: points, from: 100, count: 4)
        let journal = try ActivityJournal.open(directory: root.appendingPathComponent("act-test"))
        // Still buffered — this is the window a crash would cost.
        #expect(try journal.readFixes().isEmpty)

        try Self.walk(session, points: points, from: 104, count: 1)
        #expect(try journal.readFixes().count == 5)
    }

    @Test func timeAlsoTriggersAFlush() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(
            root: root, package: package, index: index,
            configuration: .init(flushEveryFixes: 1000, flushInterval: 60)
        )
        let points = package.plannedRoute.segments[0].points

        // Slow going: far fewer than 1000 fixes, but well past the interval.
        try Self.walk(session, points: points, from: 200, count: 6)
        let journal = try ActivityJournal.open(directory: root.appendingPathComponent("act-test"))
        #expect(try journal.readFixes().count > 0)
    }

    @Test func recoversASessionLeftBehindByACrash() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let points = package.plannedRoute.segments[0].points

        // Record, flush, then simply abandon the session object — the app being
        // killed with the phone in a pocket.
        let first = try Self.start(
            root: root, package: package, index: index,
            configuration: .init(flushEveryFixes: 5, flushInterval: 3600)
        )
        try Self.walk(first, points: points, from: 500, count: 10)

        let pending = try ActivityJournal.pendingSessions(in: root)
        #expect(pending.count == 1)

        let resumed = try RecordingSession.resume(
            journal: try #require(pending.first), package: package, index: index
        )
        // Sequence numbers continue rather than restarting, so the recovered
        // journal has no duplicate or missing seq.
        let progress = try #require(try resumed.receive(
            lat: points[510].lat, lng: points[510].lng,
            at: Date(timeIntervalSince1970: 1_700_000_200), horizontalAccuracyM: 8
        ))
        #expect(progress.fixCount == 11)

        let activity = try resumed.finish(at: Date(timeIntervalSince1970: 1_700_000_300))
        #expect(activity.status == .recovered)
        #expect(activity.diagnostics.recoveredFromCrash)
        #expect(activity.fixes.map(\.seq) == Array(1...11))
    }

    @Test func recoveryDoesNotReplayStaleDeviationsAsAlerts() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let points = package.plannedRoute.segments[0].points

        let first = try Self.start(
            root: root, package: package, index: index,
            configuration: .init(flushEveryFixes: 1, flushInterval: 1)
        )
        // Wander well off the line, then crash.
        for step in 0..<5 {
            _ = try first.receive(
                lat: points[600].lat + 0.005,
                lng: points[600].lng,
                at: Date(timeIntervalSince1970: 1_700_000_000 + Double(step) * 13),
                horizontalAccuracyM: 8
            )
        }

        let resumed = try RecordingSession.resume(
            journal: try #require(try ActivityJournal.pendingSessions(in: root).first),
            package: package, index: index
        )
        // Back on the path, hours later. The old deviation is history and must
        // not fire an alert now.
        let progress = try #require(try resumed.receive(
            lat: points[601].lat, lng: points[601].lng,
            at: Date(timeIntervalSince1970: 1_700_020_000), horizontalAccuracyM: 8
        ))
        #expect(!progress.shouldAlertOffRoute)
    }

    // MARK: - Pause, finish, discard

    @Test func pauseCommitsAndStopsConsumingFixes() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(
            root: root, package: package, index: index,
            configuration: .init(flushEveryFixes: 1000, flushInterval: 3600)
        )
        let points = package.plannedRoute.segments[0].points

        try Self.walk(session, points: points, from: 700, count: 4)
        try session.pause()

        // A pause is exactly when the phone goes away, so nothing may be left
        // sitting in memory.
        let journal = try ActivityJournal.open(directory: root.appendingPathComponent("act-test"))
        #expect(try journal.readFixes().count == 4)

        #expect(try session.receive(
            lat: points[705].lat, lng: points[705].lng,
            at: Date(timeIntervalSince1970: 1_700_000_500), horizontalAccuracyM: 8
        ) == nil)
        #expect(try journal.readFixes().count == 4)
    }

    @Test func resumingAfterAPauseDoesNotScoreAgainstAStalePosition() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(root: root, package: package, index: index)
        let points = package.plannedRoute.segments[0].points

        try Self.walk(session, points: points, from: 800, count: 5)
        try session.pause()
        session.resumeRecording()

        // A night in a refuge, then a start somewhere else on the route. Scored
        // against the old position this would look like a teleport.
        let progress = try #require(try session.receive(
            lat: points[3000].lat, lng: points[3000].lng,
            at: Date(timeIntervalSince1970: 1_700_050_000), horizontalAccuracyM: 8
        ))
        #expect(progress.confidence == .tracking)
    }

    @Test func finishFoldsEverythingIntoAnActivityPackage() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(root: root, package: package, index: index)
        let points = package.plannedRoute.segments[0].points

        try Self.walk(session, points: points, from: 1200, count: 25)
        let activity = try session.finish(at: Date(timeIntervalSince1970: 1_700_000_400))

        #expect(activity.status == .finished)
        #expect(activity.tripId == package.tripId)
        #expect(activity.tripRevision == package.revision)
        #expect(activity.stageId == "day-1")
        #expect(activity.stats.fixCount == 25)
        #expect(activity.stats.distanceM > 0)
        // The configuration in force is recorded, so a field-test result can be
        // attributed to a setup rather than to a memory of one.
        #expect(activity.nativeConfig.distanceFilterM == 15)
        #expect(activity.nativeConfig.allowsBackgroundUpdates)
    }

    @Test func discardRemovesTheJournalEntirely() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(root: root, package: package, index: index)
        let points = package.plannedRoute.segments[0].points

        try Self.walk(session, points: points, from: 900, count: 3)
        try session.discard()

        #expect(try ActivityJournal.pendingSessions(in: root).isEmpty)
    }

    @Test func aWalkOnTheRouteRaisesNoFalseAlerts() throws {
        let root = try Self.makeRoot()
        let (package, index) = try Self.tmb()
        let session = try Self.start(root: root, package: package, index: index)
        let points = package.plannedRoute.segments[0].points

        // 100 fixes, ~20 minutes, on the line with a normal accuracy figure.
        let progress = try Self.walk(session, points: points, from: 4000, count: 100)
        #expect(!progress.contains { $0.shouldAlertOffRoute })
        #expect(progress.allSatisfy { $0.offRouteState == .onRoute })
    }
}
