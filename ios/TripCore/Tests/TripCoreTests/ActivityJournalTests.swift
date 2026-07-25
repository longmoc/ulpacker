import Foundation
import Testing
@testable import TripCore

/// Tests for the recording journal.
///
/// The scenarios that matter here are all failure scenarios: the app being
/// killed mid-write, a session found on disk at launch, a fix that arrived with
/// useless accuracy. Those are the conditions the recorder actually meets in a
/// pocket on a mountain, and they are cheap to reproduce on a Mac — which is the
/// whole reason this logic lives in TripCore rather than in the app target.
struct ActivityJournalTests {
    static func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ulpacker-journal-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func makeSession(id: String = "act-1", startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000))
        -> ActivityJournal.Session
    {
        ActivityJournal.Session(
            activityId: id,
            tripId: "trip_tmb_ccw",
            tripRevision: 1,
            stageId: "day-1",
            startedAt: startedAt,
            nativeConfig: .init(
                desiredAccuracy: "kCLLocationAccuracyBest",
                distanceFilterM: 15,
                activityType: "fitness",
                pausesAutomatically: false,
                allowsBackgroundUpdates: true
            )
        )
    }

    /// Points roughly 15 m apart along a line, one per 13 s — a walking pace at
    /// the default distance filter.
    static func makeFixes(count: Int, startSeq: Int = 1, hAcc: Double = 8) -> [ActivityPackage.Fix] {
        (0..<count).map { index in
            ActivityPackage.Fix(
                seq: startSeq + index,
                t: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 13),
                lat: 45.9 + Double(index) * 0.000135,
                lng: 6.8,
                hAcc: hAcc,
                alt: 1000 + Double(index),
                speed: 1.2,
                bearing: 0
            )
        }
    }

    // MARK: - Lifecycle

    @Test func writesTheSessionHeaderBeforeAnyFix() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())

        // The header has to survive a crash one second into the walk, so it is
        // on disk before location updates ever start.
        let headerURL = journal.directory.appendingPathComponent("session.json")
        #expect(FileManager.default.fileExists(atPath: headerURL.path))
        #expect(try journal.readFixes().isEmpty)
    }

    @Test func refusesToReuseAnExistingSessionDirectory() throws {
        let root = try Self.makeRoot()
        _ = try ActivityJournal.create(in: root, session: Self.makeSession())
        #expect(throws: ActivityJournal.JournalError.sessionAlreadyExists("act-1")) {
            _ = try ActivityJournal.create(in: root, session: Self.makeSession())
        }
    }

    @Test func reopeningRestoresTheSession() throws {
        let root = try Self.makeRoot()
        let created = try ActivityJournal.create(in: root, session: Self.makeSession())
        try created.append(contentsOf: Self.makeFixes(count: 3))

        let reopened = try ActivityJournal.open(directory: created.directory)
        #expect(reopened.session == created.session)
        #expect(try reopened.readFixes().count == 3)
    }

    @Test func listsPendingSessionsOldestFirst() throws {
        let root = try Self.makeRoot()
        _ = try ActivityJournal.create(
            in: root,
            session: Self.makeSession(id: "later", startedAt: Date(timeIntervalSince1970: 2_000))
        )
        _ = try ActivityJournal.create(
            in: root,
            session: Self.makeSession(id: "earlier", startedAt: Date(timeIntervalSince1970: 1_000))
        )

        // A non-empty result at launch is how the app knows a walk was
        // interrupted and offers to resume it.
        let pending = try ActivityJournal.pendingSessions(in: root)
        #expect(pending.map(\.session.activityId) == ["earlier", "later"])
    }

    @Test func returnsNoPendingSessionsWhenNothingWasRecorded() throws {
        let root = try Self.makeRoot()
        #expect(try ActivityJournal.pendingSessions(in: root).isEmpty)
        // A root that does not exist yet is the first-launch case, not an error.
        let missing = root.appendingPathComponent("never-created")
        #expect(try ActivityJournal.pendingSessions(in: missing).isEmpty)
    }

    // MARK: - Append and recovery

    @Test func appendsAccumulateAcrossCalls() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())
        try journal.append(Self.makeFixes(count: 1)[0])
        try journal.append(contentsOf: Self.makeFixes(count: 4, startSeq: 2))

        let fixes = try journal.readFixes()
        #expect(fixes.count == 5)
        #expect(fixes.map(\.seq) == [1, 2, 3, 4, 5])
    }

    @Test func emptyBatchIsANoOp() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())
        try journal.append(contentsOf: [])
        #expect(try journal.readFixes().isEmpty)
    }

    @Test func survivesATornFinalLine() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())
        try journal.append(contentsOf: Self.makeFixes(count: 5))

        // Simulate the process being killed halfway through writing fix 6.
        let fixesURL = journal.directory.appendingPathComponent("fixes.ndjson")
        var raw = try Data(contentsOf: fixesURL)
        raw.append(contentsOf: Array(#"{"seq":6,"lat":45.9,"#.utf8))
        try raw.write(to: fixesURL)

        // Losing the torn fix is the designed-for cost; refusing to open the
        // file would throw away the entire walk instead of one observation.
        let fixes = try journal.readFixes()
        #expect(fixes.count == 5)
        #expect(try journal.lastCommittedSequence() == 5)
    }

    @Test func reportsNoSequenceForAnEmptyJournal() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())
        #expect(try journal.lastCommittedSequence() == nil)
    }

    @Test func rejectsOpeningADirectoryWithNoHeader() throws {
        let root = try Self.makeRoot()
        let orphan = root.appendingPathComponent("not-a-session")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        #expect(throws: ActivityJournal.JournalError.sessionMissing) {
            _ = try ActivityJournal.open(directory: orphan)
        }
    }

    // MARK: - Packaging

    @Test func foldsTheJournalIntoAPackage() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())
        try journal.append(contentsOf: Self.makeFixes(count: 10))

        let package = try journal.makePackage(
            status: .finished,
            endedAt: Date(timeIntervalSince1970: 1_700_000_000 + 9 * 13),
            maxAccuracyM: 50
        )

        #expect(package.format == ActivityPackage.expectedFormat)
        #expect(package.tripId == "trip_tmb_ccw")
        #expect(package.stats.fixCount == 10)
        #expect(package.stats.usableFixCount == 10)
        #expect(package.stats.durationS == 117)
        // Nine steps of ~15 m.
        #expect(package.stats.distanceM >= 130 && package.stats.distanceM <= 140)
    }

    @Test func keepsBadFixesButExcludesThemFromDistance() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())
        try journal.append(contentsOf: Self.makeFixes(count: 3))
        // A wild fix 2 km away with useless accuracy — the classic urban-canyon
        // or under-canopy artefact.
        try journal.append(
            ActivityPackage.Fix(
                seq: 4,
                t: Date(timeIntervalSince1970: 1_700_000_040),
                lat: 45.92,
                lng: 6.8,
                hAcc: 300
            )
        )

        let package = try journal.makePackage(status: .finished, endedAt: nil, maxAccuracyM: 50)

        // Recorded for debugging, excluded from decisions: counting it would add
        // 2 km of noise to a 30 m walk.
        #expect(package.stats.fixCount == 4)
        #expect(package.stats.usableFixCount == 3)
        #expect(package.diagnostics.rejectedFixCount == 1)
        #expect(package.stats.distanceM < 50)
        #expect(package.fixes.count == 4)
    }

    @Test func treatsNegativeAccuracyAsUnusable() {
        // Core Location reports a negative horizontalAccuracy when the fix is
        // invalid; a naive `hAcc <= limit` check would accept it.
        let invalid = ActivityPackage.Fix(seq: 1, t: Date(), lat: 45.9, lng: 6.8, hAcc: -1)
        #expect(!invalid.isUsable(maxAccuracyM: 50))

        let good = ActivityPackage.Fix(seq: 2, t: Date(), lat: 45.9, lng: 6.8, hAcc: 8)
        #expect(good.isUsable(maxAccuracyM: 50))
    }

    @Test func reportsTheLargestGapNotTheAverage() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())
        try journal.append(contentsOf: Self.makeFixes(count: 3))
        // A ten-minute hole: signal lost in a gully. A mean would hide this.
        try journal.append(
            ActivityPackage.Fix(
                seq: 4,
                t: Date(timeIntervalSince1970: 1_700_000_000 + 26 + 600),
                lat: 45.9 + 3 * 0.000135,
                lng: 6.8,
                hAcc: 8
            )
        )

        let package = try journal.makePackage(status: .finished, endedAt: nil, maxAccuracyM: 50)
        #expect(package.diagnostics.maxGapS == 600)
    }

    @Test func marksRecoveredSessions() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())
        try journal.append(contentsOf: Self.makeFixes(count: 2))

        let package = try journal.makePackage(
            status: .recovered,
            endedAt: nil,
            maxAccuracyM: 50,
            recoveredFromCrash: true
        )
        #expect(package.status == .recovered)
        #expect(package.diagnostics.recoveredFromCrash)
        // No end time was ever written, so it falls back to the last observation.
        #expect(package.endedAt == nil)
        #expect(package.stats.durationS == 13)
    }

    @Test func packageRoundTripsThroughJSON() throws {
        let root = try Self.makeRoot()
        let journal = try ActivityJournal.create(in: root, session: Self.makeSession())
        try journal.append(contentsOf: Self.makeFixes(count: 4))
        // Millisecond precision on purpose: that is what the contract carries,
        // matching JavaScript's Date. A raw `Date()` holds sub-millisecond
        // precision that no ISO 8601 timestamp on either side can represent.
        let endedAt = Date(timeIntervalSince1970: 1_700_000_117.250)
        let package = try journal.makePackage(status: .finished, endedAt: endedAt, maxAccuracyM: 50)

        let data = try ISO8601.encoder().encode(package)
        let restored = try ISO8601.decoder().decode(ActivityPackage.self, from: data)
        #expect(restored == package)
    }

    @Test func timestampsSurviveARoundTripToTheMillisecond() {
        // Foundation's default .iso8601 truncates to whole seconds, so an
        // encoded package would not equal the one that went in.
        let precise = Date(timeIntervalSince1970: 1_700_000_000.472)
        let text = ISO8601.string(from: precise)
        #expect(text.contains(".472"))
        #expect(ISO8601.date(from: text) == precise)
    }

    @Test func acceptsTimestampsWrittenByJavaScript() {
        // `new Date().toISOString()` always emits milliseconds; the default
        // strategy would fail on exactly the format the planner produces.
        #expect(ISO8601.date(from: "2026-07-25T07:46:27.472Z") != nil)
        // And plain second precision still parses, for anything that omits them.
        #expect(ISO8601.date(from: "2026-07-25T07:46:27Z") != nil)
        #expect(ISO8601.date(from: "not a date") == nil)
    }

    // MARK: - Shared geometry

    @Test func haversineMatchesTheJavaScriptImplementation() {
        // Same formula and same earth radius as trail.js, so a distance shown in
        // the app and the same distance shown on the web agree.
        let oneDegreeOfLatitude = ActivityJournal.haversine(45, 6, 46, 6)
        #expect(abs(oneDegreeOfLatitude - 111_195) < 50)

        #expect(ActivityJournal.haversine(45.9, 6.8, 45.9, 6.8) == 0)
    }
}
