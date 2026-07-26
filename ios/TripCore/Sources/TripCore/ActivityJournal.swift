import Foundation

/// Crash-safe, append-only storage for a recording session.
///
/// The design constraint that shapes everything here: iOS can kill the app at
/// any moment while the phone is in a pocket with the screen off, and whatever
/// reached the disk is all that survives. So the journal is written forward
/// only — a session header first, then one line per fix — and never rewritten.
/// There is no "save on exit" step to miss.
///
/// Layout, one directory per session:
///
///     activities/<activityId>/session.json    written before recording starts
///     activities/<activityId>/fixes.ndjson    one JSON object per line
///
/// Newline-delimited JSON rather than one array: appending to an array means
/// rewriting the closing bracket every time, and a process killed mid-rewrite
/// loses the whole file. With NDJSON a torn final line costs one fix, and
/// `open(from:)` simply drops it.
public struct ActivityJournal: Sendable {
    public struct Session: Codable, Sendable, Equatable {
        public let activityId: String
        public let tripId: String
        public let tripRevision: Int
        public let stageId: String?
        public let startedAt: Date
        public let nativeConfig: ActivityPackage.NativeConfig

        public init(
            activityId: String,
            tripId: String,
            tripRevision: Int,
            stageId: String?,
            startedAt: Date,
            nativeConfig: ActivityPackage.NativeConfig
        ) {
            self.activityId = activityId
            self.tripId = tripId
            self.tripRevision = tripRevision
            self.stageId = stageId
            self.startedAt = startedAt
            self.nativeConfig = nativeConfig
        }
    }

    public enum JournalError: Error, Equatable {
        case sessionMissing
        case sessionAlreadyExists(String)
    }

    public let directory: URL
    public let session: Session

    private var sessionURL: URL { directory.appendingPathComponent("session.json") }
    private var fixesURL: URL { directory.appendingPathComponent("fixes.ndjson") }

    // Fractional seconds on both sides — see ISO8601 for why the built-in
    // strategy is unusable here.
    private static func encoder() -> JSONEncoder { ISO8601.encoder() }
    private static func decoder() -> JSONDecoder { ISO8601.decoder() }

    // MARK: - Lifecycle

    /// Create a session directory and commit its header **before** location
    /// updates start. If the app dies one second into a walk, the session still
    /// exists and is recoverable; a header written lazily on the first fix
    /// would leave nothing behind.
    public static func create(in root: URL, session: Session) throws -> ActivityJournal {
        let directory = root.appendingPathComponent(session.activityId, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            throw JournalError.sessionAlreadyExists(session.activityId)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = ActivityJournal(directory: directory, session: session)
        try encoder().encode(session).write(to: journal.sessionURL, options: .atomic)
        FileManager.default.createFile(atPath: journal.fixesURL.path, contents: nil)
        return journal
    }

    /// Reopen an existing session directory — the recovery path after a crash.
    public static func open(directory: URL) throws -> ActivityJournal {
        let sessionURL = directory.appendingPathComponent("session.json")
        guard FileManager.default.fileExists(atPath: sessionURL.path) else {
            throw JournalError.sessionMissing
        }
        let session = try decoder().decode(Session.self, from: Data(contentsOf: sessionURL))
        return ActivityJournal(directory: directory, session: session)
    }

    /// Every session directory under `root`, oldest first. A non-empty result
    /// at launch means a previous run did not finish cleanly.
    public static func pendingSessions(in root: URL) throws -> [ActivityJournal] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return entries
            .compactMap { try? open(directory: $0) }
            .sorted { $0.session.startedAt < $1.session.startedAt }
    }

    // MARK: - Append

    /// Append one fix. Opens, seeks, writes, closes — the file handle is not
    /// held across calls, so a kill between fixes cannot leave a lock or a
    /// partially flushed buffer behind.
    public func append(_ fix: ActivityPackage.Fix) throws {
        var line = try Self.encoder().encode(fix)
        line.append(0x0A)
        let handle = try FileHandle(forWritingTo: fixesURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Append a batch in one open/write/close.
    ///
    /// This is the normal path while recording: buffering in memory and
    /// flushing periodically keeps the flash writes (and the wakeups they
    /// cause) proportional to time rather than to every GPS fix, which is the
    /// difference the battery notices. The cost of a crash is bounded by how
    /// often the caller flushes.
    public func append(contentsOf fixes: [ActivityPackage.Fix]) throws {
        guard !fixes.isEmpty else { return }
        let encoder = Self.encoder()
        var buffer = Data()
        for fix in fixes {
            buffer.append(try encoder.encode(fix))
            buffer.append(0x0A)
        }
        let handle = try FileHandle(forWritingTo: fixesURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: buffer)
    }

    // MARK: - Read back

    /// Read every complete fix, in file order.
    ///
    /// A trailing partial line — the signature of a process killed mid-write —
    /// is dropped rather than treated as corruption. Losing the last fix is the
    /// designed-for cost; refusing to open the file would throw away the walk.
    public func readFixes() throws -> [ActivityPackage.Fix] {
        let data = try Data(contentsOf: fixesURL)
        guard !data.isEmpty else { return [] }
        let decoder = Self.decoder()
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(ActivityPackage.Fix.self, from: Data($0)) }
    }

    /// The highest sequence number safely on disk, or nil for an empty journal.
    /// Recording resumes from here so a recovered session never reuses a `seq`.
    public func lastCommittedSequence() throws -> Int? {
        try readFixes().last?.seq
    }

    public func delete() throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Finish

    /// Fold the journal into the immutable package that leaves this device.
    public func makePackage(
        status: ActivityPackage.Status,
        endedAt: Date?,
        maxAccuracyM: Double,
        recoveredFromCrash: Bool = false
    ) throws -> ActivityPackage {
        let fixes = try readFixes()
        let usable = fixes.filter { $0.isUsable(maxAccuracyM: maxAccuracyM) }

        // Distance follows the usable fixes only: including rejected ones would
        // add GPS noise as real walked metres, inflating every summary.
        var distance = 0.0
        var maxGapS = 0.0
        var maxGapM = 0.0
        for (previous, next) in zip(usable, usable.dropFirst()) {
            let step = Self.haversine(previous.lat, previous.lng, next.lat, next.lng)
            distance += step
            maxGapM = max(maxGapM, step)
            maxGapS = max(maxGapS, next.t.timeIntervalSince(previous.t))
        }

        let end = endedAt ?? fixes.last?.t ?? session.startedAt
        return ActivityPackage(
            format: ActivityPackage.expectedFormat,
            schemaVersion: ActivityPackage.supportedSchemaVersion,
            activityId: session.activityId,
            tripId: session.tripId,
            tripRevision: session.tripRevision,
            stageId: session.stageId,
            status: status,
            startedAt: session.startedAt,
            endedAt: endedAt,
            nativeConfig: session.nativeConfig,
            fixes: fixes,
            stats: .init(
                fixCount: fixes.count,
                usableFixCount: usable.count,
                distanceM: Int(distance.rounded()),
                durationS: Int(end.timeIntervalSince(session.startedAt).rounded())
            ),
            diagnostics: .init(
                maxGapS: Int(maxGapS.rounded()),
                maxGapM: Int(maxGapM.rounded()),
                rejectedFixCount: fixes.count - usable.count,
                recoveredFromCrash: recoveredFromCrash
            )
        )
    }

    /// Mirrors `haversine()` in trail.js, including its earth radius, so the
    /// two sides report the same distance for the same points.
    public static func haversine(_ aLat: Double, _ aLng: Double, _ bLat: Double, _ bLng: Double) -> Double {
        let radius = 6_371_000.0
        let toRad = Double.pi / 180
        let dLat = (bLat - aLat) * toRad
        let dLng = (bLng - aLng) * toRad
        let lat1 = aLat * toRad
        let lat2 = bLat * toRad
        let h = sin(dLat / 2) * sin(dLat / 2)
            + sin(dLng / 2) * sin(dLng / 2) * cos(lat1) * cos(lat2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }
}
