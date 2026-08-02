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
    private var powerURL: URL { directory.appendingPathComponent("power.ndjson") }
    /// Written when the walk is closed out. Its presence is what separates a
    /// finished walk from one the app died in the middle of — the difference
    /// between "here is your day" and "shall I carry on?".
    private var activityURL: URL { directory.appendingPathComponent("activity.json") }

    // Fractional seconds on both sides — see ISO8601 for why the built-in
    // strategy is unusable here.
    private static func encoder() -> JSONEncoder { ISO8601.encoder() }
    private static func decoder() -> JSONDecoder { ISO8601.decoder() }
    private func encoder() -> JSONEncoder { Self.encoder() }
    private func decoder() -> JSONDecoder { Self.decoder() }

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

    /// Whether this walk was closed out properly.
    public var isFinished: Bool {
        FileManager.default.fileExists(atPath: activityURL.path)
    }

    /// The finished walk, if there is one.
    public func finishedPackage() throws -> ActivityPackage? {
        guard isFinished else { return nil }
        return try decoder().decode(ActivityPackage.self, from: Data(contentsOf: activityURL))
    }

    /// Commit the finished walk beside its journal.
    ///
    /// Written before the recorder lets go of the session, so the walk survives
    /// everything from here on. It used to survive nothing: `finish()` returned
    /// the package to the screen, the screen printed one line, and the next tap
    /// deleted the directory. Nine days of walking could be lost to a button
    /// labelled "Start another".
    public func commit(_ package: ActivityPackage) throws {
        try encoder().encode(package).write(to: activityURL, options: .atomic)
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
            // A finished walk is not an interruption. Without this the app
            // offered to continue a walk it had already closed, every launch,
            // for as long as the directory sat there.
            .filter { !$0.isFinished }
            .sorted { $0.session.startedAt < $1.session.startedAt }
    }

    /// Every finished walk under `root`, newest first — the activity history.
    public static func finishedActivities(in root: URL) throws -> [ActivityPackage] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        return entries
            .compactMap { try? open(directory: $0) }
            .compactMap { try? $0.finishedPackage() }
            .compactMap { $0 }
            .sorted { $0.startedAt > $1.startedAt }
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

    /// Append battery samples, in the same open/write/close shape as fixes and
    /// on the same schedule, so measuring the battery never costs a wakeup of
    /// its own. Measurement that changes what it measures is worth nothing.
    public func appendPower(contentsOf samples: [Power.Sample]) throws {
        guard !samples.isEmpty else { return }
        let encoder = Self.encoder()
        var buffer = Data()
        for sample in samples {
            buffer.append(try encoder.encode(sample))
            buffer.append(0x0A)
        }
        if !FileManager.default.fileExists(atPath: powerURL.path) {
            FileManager.default.createFile(atPath: powerURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: powerURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: buffer)
    }

    public func readPowerSamples() throws -> [Power.Sample] {
        guard FileManager.default.fileExists(atPath: powerURL.path) else { return [] }
        let data = try Data(contentsOf: powerURL)
        guard !data.isEmpty else { return [] }
        let decoder = Self.decoder()
        return data
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(Power.Sample.self, from: Data($0)) }
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

        // Distance follows the usable fixes only, through the same rule the
        // live readout uses — a walk cannot be one length while it happens and
        // another once it is saved.
        let distance = WalkedDistance.total(
            of: fixes, maxAccuracyM: maxAccuracyM
        )
        var maxGapS = 0.0
        var maxGapM = 0.0
        for (previous, next) in zip(usable, usable.dropFirst()) {
            // Gaps still count every step, including the ones the distance
            // rule discards: a jump that was not walked is exactly the kind of
            // thing the diagnostics exist to show.
            let step = Self.haversine(previous.lat, previous.lng, next.lat, next.lng)
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
            ),
            power: Power.report(for: (try? readPowerSamples()) ?? [])
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
