import Foundation

/// A downloaded map region, stored on disk and tied to one trip.
///
/// The failure this type exists to prevent: a pack that is *almost* there. A
/// download interrupted in a car park leaves a plausible-looking file that
/// fails halfway up a valley, which is the worst possible time to discover it.
/// So a pack is written to a `.partial` path, verified, and only then renamed —
/// a file at its final name is, by construction, complete and checked.
public struct OfflinePack: Sendable, Equatable {
    /// Metadata written beside the tiles so a pack can be judged without
    /// opening it: which trip and revision it was cut for, and what it covers.
    public struct Manifest: Codable, Sendable, Equatable {
        public static let currentVersion = 1

        public let manifestVersion: Int
        public let tripId: String
        public let tripRevision: Int
        /// The route corridor this pack covers, as [west, south, east, north].
        public let bbox: [Double]
        public let minZoom: Int
        public let maxZoom: Int
        public let byteCount: Int
        /// FNV-1a over the tile file, using the same helper as TripPackage.
        public let contentHash: String
        public let source: String
        public let createdAt: Date

        public init(
            manifestVersion: Int = Manifest.currentVersion,
            tripId: String,
            tripRevision: Int,
            bbox: [Double],
            minZoom: Int,
            maxZoom: Int,
            byteCount: Int,
            contentHash: String,
            source: String,
            createdAt: Date
        ) {
            self.manifestVersion = manifestVersion
            self.tripId = tripId
            self.tripRevision = tripRevision
            self.bbox = bbox
            self.minZoom = minZoom
            self.maxZoom = maxZoom
            self.byteCount = byteCount
            self.contentHash = contentHash
            self.source = source
            self.createdAt = createdAt
        }
    }

    public enum PackError: Error, Equatable, CustomStringConvertible {
        case notPMTiles
        case unsupportedPMTilesVersion(UInt8)
        case sizeMismatch(expected: Int, actual: Int)
        case hashMismatch(expected: String, actual: String)
        case manifestMissing
        case unsupportedManifestVersion(Int)
        case wrongTrip(expected: String, found: String)

        public var description: String {
            switch self {
            case .notPMTiles: "Not a PMTiles archive."
            case .unsupportedPMTilesVersion(let v): "PMTiles version \(v) is not supported (needs 3)."
            case .sizeMismatch(let e, let a): "Incomplete download: expected \(e) bytes, got \(a)."
            case .hashMismatch: "The map pack is corrupt (content hash mismatch)."
            case .manifestMissing: "The map pack has no manifest."
            case .unsupportedManifestVersion(let v): "Manifest version \(v) is not supported."
            case .wrongTrip(let e, let f): "This pack is for trip \(f), not \(e)."
            }
        }
    }

    public let directory: URL
    public let manifest: Manifest

    public var tilesURL: URL { directory.appendingPathComponent("tiles.pmtiles") }
    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    /// The URL MapLibre needs. Its PMTiles source takes a `pmtiles://` scheme
    /// wrapping an ordinary file URL — no HTTP, no range requests, nothing that
    /// can fail without signal.
    public var mapLibreURL: URL? {
        URL(string: "pmtiles://\(tilesURL.absoluteString)")
    }

    // MARK: - Reading

    public static func open(directory: URL, expectedTripId: String? = nil) throws -> OfflinePack {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PackError.manifestMissing
        }
        let manifest = try ISO8601.decoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.manifestVersion == Manifest.currentVersion else {
            throw PackError.unsupportedManifestVersion(manifest.manifestVersion)
        }
        if let expectedTripId, manifest.tripId != expectedTripId {
            throw PackError.wrongTrip(expected: expectedTripId, found: manifest.tripId)
        }
        return OfflinePack(directory: directory, manifest: manifest)
    }

    /// Packs present for a trip, newest first.
    public static func installed(in root: URL, tripId: String? = nil) -> [OfflinePack] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .compactMap { try? open(directory: $0, expectedTripId: tripId) }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// Re-check a pack already on disk. Cheap enough to run when a trip opens;
    /// catches a file truncated by a full disk or a botched sync.
    public func verify() throws {
        let data = try Data(contentsOf: tilesURL, options: .mappedIfSafe)
        try Self.validate(data: data, against: manifest)
    }

    // MARK: - Installing

    /// Install tile bytes as a pack, verifying before anything is named.
    ///
    /// `install` is the only way to create a pack, so there is no path that
    /// produces an unverified one.
    @discardableResult
    public static func install(
        tiles: Data,
        manifest: Manifest,
        in root: URL,
        packId: String = UUID().uuidString
    ) throws -> OfflinePack {
        try validate(data: tiles, against: manifest)

        let directory = root.appendingPathComponent(packId, isDirectory: true)
        let partial = root.appendingPathComponent("\(packId).partial", isDirectory: true)
        try? FileManager.default.removeItem(at: partial)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        try tiles.write(to: partial.appendingPathComponent("tiles.pmtiles"), options: .atomic)
        try ISO8601.encoder().encode(manifest)
            .write(to: partial.appendingPathComponent("manifest.json"), options: .atomic)

        // The rename is the commit. Anything that fails before this leaves only
        // a `.partial` directory, which is never mistaken for a usable pack.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: partial, to: directory)

        return OfflinePack(directory: directory, manifest: manifest)
    }

    /// Remove abandoned `.partial` directories — a download killed mid-write
    /// leaves one behind, and they are pure waste on a phone with a full disk.
    @discardableResult
    public static func cleanUpPartials(in root: URL) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for entry in entries where entry.lastPathComponent.hasSuffix(".partial") {
            if (try? FileManager.default.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }

    public func delete() throws {
        try FileManager.default.removeItem(at: directory)
    }

    // MARK: - Validation

    static func validate(data: Data, against manifest: Manifest) throws {
        // Size first: it is the cheapest check and catches the common case, a
        // download that stopped early.
        guard data.count == manifest.byteCount else {
            throw PackError.sizeMismatch(expected: manifest.byteCount, actual: data.count)
        }
        try validatePMTilesHeader(data)

        let actual = FNV1a.hash64(bytes: data)
        guard actual == manifest.contentHash else {
            throw PackError.hashMismatch(expected: manifest.contentHash, actual: actual)
        }
    }

    /// PMTiles v3 begins with the ASCII magic "PMTiles" followed by a version
    /// byte. Checking it means a truncated or wrong-format file is rejected
    /// with a clear message rather than by MapLibre failing to draw anything.
    static func validatePMTilesHeader(_ data: Data) throws {
        let magic = Array("PMTiles".utf8)
        guard data.count > magic.count else { throw PackError.notPMTiles }
        for (index, byte) in magic.enumerated() where data[data.startIndex + index] != byte {
            throw PackError.notPMTiles
        }
        let version = data[data.startIndex + magic.count]
        guard version == 3 else { throw PackError.unsupportedPMTilesVersion(version) }
    }
}

extension FNV1a {
    /// Hash raw bytes. Same algorithm as the text form, so a Swift and a JS
    /// implementation still agree; used here for file integrity rather than for
    /// the TripPackage content identity.
    public static func hash64(bytes data: Data) -> String {
        let prime: UInt64 = 0x100_0000_01b3
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* prime
        }
        return String(format: "%016lx", hash)
    }
}
