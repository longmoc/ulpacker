import Foundation
import Testing
@testable import TripCore

/// The recovery boundary, where a crashed walk is reopened.
///
/// Two things must hold and neither is about the happy path. A journal must be
/// resumed only against the exact trip it was recorded on — the wrong route
/// makes every number a confident lie. And what the matcher and the distance
/// counter had reached must come back, because a nearest-point guess cannot
/// recover an accepted branch or a running sum.
@MainActor
struct RecoverySafetyTests {
    static func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ulpacker-recovery-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func session(
        tripId: String, tripRevision: Int, in root: URL
    ) -> ActivityJournal.Session {
        .init(
            activityId: UUID().uuidString,
            tripId: tripId,
            tripRevision: tripRevision,
            stageId: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            nativeConfig: RecordingSessionTests.nativeConfig
        )
    }

    // MARK: - The safety stop (issue 2.1)

    @Test func resumeRefusesAJournalFromAnotherTrip() throws {
        let root = try Self.makeRoot()
        let (package, index) = try RecordingSessionTests.tmb()

        // A journal left behind by some other trip entirely.
        let journal = try ActivityJournal.create(
            in: root,
            session: Self.session(tripId: "not-\(package.tripId)", tripRevision: package.revision, in: root)
        )

        #expect(throws: RecordingSession.ResumeError.self) {
            _ = try RecordingSession.resume(journal: journal, package: package, index: index)
        }
    }

    @Test func resumeRefusesAJournalFromAnEarlierRevision() throws {
        let root = try Self.makeRoot()
        let (package, index) = try RecordingSessionTests.tmb()

        // Same trip, but the package on the phone has been re-exported since —
        // the line may have moved, so its metres no longer mean the same thing.
        let journal = try ActivityJournal.create(
            in: root,
            session: Self.session(tripId: package.tripId, tripRevision: package.revision - 1, in: root)
        )

        do {
            _ = try RecordingSession.resume(journal: journal, package: package, index: index)
            Issue.record("expected a tripMismatch, resumed instead")
        } catch let error as RecordingSession.ResumeError {
            #expect(error == .tripMismatch(
                journalTripId: package.tripId, journalRevision: package.revision - 1,
                packageTripId: package.tripId, packageRevision: package.revision
            ))
        }
    }

    @Test func resumeAcceptsTheMatchingTripAndRevision() throws {
        let root = try Self.makeRoot()
        let (package, index) = try RecordingSessionTests.tmb()
        let points = package.plannedRoute.segments[0].points

        let first = try RecordingSessionTests.start(
            root: root, package: package, index: index,
            configuration: .init(flushEveryFixes: 3, flushInterval: 3600)
        )
        try RecordingSessionTests.walk(first, points: points, from: 400, count: 6)

        // Same package it was started on — this must not throw.
        let resumed = try RecordingSession.resume(
            journal: try #require(try ActivityJournal.pendingSessions(in: root).first),
            package: package, index: index
        )
        #expect(resumed.state == .recording)
    }

    // MARK: - Cursor recovery (issue 2.4)

    @Test func walkedDistanceAndPositionSurviveACrash() throws {
        let root = try Self.makeRoot()
        let (package, index) = try RecordingSessionTests.tmb()
        let points = package.plannedRoute.segments[0].points

        // Flush often, so the cursor is up to date when the crash happens.
        let first = try RecordingSessionTests.start(
            root: root, package: package, index: index,
            configuration: .init(flushEveryFixes: 2, flushInterval: 3600)
        )
        let before = try RecordingSessionTests.walk(first, points: points, from: 300, count: 20)
        let lastBefore = try #require(before.last)
        #expect(lastBefore.walkedM > 0)

        // The cursor is on disk, describing where the walk had got to.
        let pending = try #require(try ActivityJournal.pendingSessions(in: root).first)
        let cursor = try #require(try pending.readCursor())
        #expect(abs(cursor.walkedM - lastBefore.walkedM) < 1)

        // Abandon the object — a kill — and reopen.
        let resumed = try RecordingSession.resume(
            journal: try #require(try ActivityJournal.pendingSessions(in: root).first),
            package: package, index: index
        )
        let after = try #require(try resumed.receive(
            lat: points[321].lat, lng: points[321].lng,
            at: Date(timeIntervalSince1970: 1_700_000_400), horizontalAccuracyM: 8
        ))

        // Walked distance carried over rather than resetting to zero, and route
        // progress continued from where it was rather than jumping back to the
        // start of the line.
        #expect(after.walkedM >= lastBefore.walkedM)
        #expect(abs(after.routeDistanceM - lastBefore.routeDistanceM) < 500)
    }

    @Test func recoveredWalkedDistanceMatchesTheFinishedPackage() throws {
        let root = try Self.makeRoot()
        let (package, index) = try RecordingSessionTests.tmb()
        let points = package.plannedRoute.segments[0].points

        let first = try RecordingSessionTests.start(
            root: root, package: package, index: index,
            configuration: .init(flushEveryFixes: 2, flushInterval: 3600)
        )
        try RecordingSessionTests.walk(first, points: points, from: 300, count: 20)

        let resumed = try RecordingSession.resume(
            journal: try #require(try ActivityJournal.pendingSessions(in: root).first),
            package: package, index: index
        )
        let progress = try #require(try resumed.receive(
            lat: points[321].lat, lng: points[321].lng,
            at: Date(timeIntervalSince1970: 1_700_000_400), horizontalAccuracyM: 8
        ))
        let activity = try resumed.finish(at: Date(timeIntervalSince1970: 1_700_000_500))

        // The live number after recovery and the number summed from the whole
        // journal at finish must agree — the drift the cursor exists to prevent.
        #expect(abs(Double(activity.stats.distanceM) - progress.walkedM) < 1)
    }

    @Test func withoutACursorRecoveryStillWorks() throws {
        let root = try Self.makeRoot()
        let (package, index) = try RecordingSessionTests.tmb()
        let points = package.plannedRoute.segments[0].points

        let first = try RecordingSessionTests.start(
            root: root, package: package, index: index,
            configuration: .init(flushEveryFixes: 2, flushInterval: 3600)
        )
        try RecordingSessionTests.walk(first, points: points, from: 300, count: 10)

        // An older journal has no cursor file. Delete it and prove the
        // nearest-point fallback still reopens the walk safely.
        let journal = try #require(try ActivityJournal.pendingSessions(in: root).first)
        try FileManager.default.removeItem(
            at: journal.directory.appendingPathComponent("cursor.json")
        )
        #expect(try journal.readCursor() == nil)

        let resumed = try RecordingSession.resume(journal: journal, package: package, index: index)
        let progress = try #require(try resumed.receive(
            lat: points[311].lat, lng: points[311].lng,
            at: Date(timeIntervalSince1970: 1_700_000_400), horizontalAccuracyM: 8
        ))
        // Position recovered from the last fix, so progress is sensible rather
        // than back at metre zero. Walked distance cannot be recovered here.
        #expect(progress.routeDistanceM > 0)
    }
}
