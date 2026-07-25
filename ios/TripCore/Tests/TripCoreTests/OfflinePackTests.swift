import Foundation
import Testing
@testable import TripCore

/// Tests for the offline map pack.
///
/// The scenario worth guarding is a pack that is *almost* right: a download cut
/// short in a car park produces a plausible file that fails halfway up a
/// valley. Every check here exists so that failure happens at install time,
/// where there is still signal to fix it.
struct OfflinePackTests {
    static func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ulpacker-pack-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Minimal bytes that pass the PMTiles v3 header check.
    static func fakeTiles(padding: Int = 64) -> Data {
        var data = Data("PMTiles".utf8)
        data.append(3)
        data.append(Data(repeating: 0x42, count: padding))
        return data
    }

    static func manifest(for tiles: Data, tripId: String = "trip_tmb_ccw", revision: Int = 1)
        -> OfflinePack.Manifest
    {
        OfflinePack.Manifest(
            tripId: tripId,
            tripRevision: revision,
            bbox: [6.5131, 45.5603, 7.3219, 46.1932],
            minZoom: 0,
            maxZoom: 14,
            byteCount: tiles.count,
            contentHash: FNV1a.hash64(bytes: tiles),
            source: "https://build.protomaps.com/20260725.pmtiles",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Install

    @Test func installsAndReopensAPack() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        let pack = try OfflinePack.install(tiles: tiles, manifest: Self.manifest(for: tiles), in: root)

        #expect(FileManager.default.fileExists(atPath: pack.tilesURL.path))
        let reopened = try OfflinePack.open(directory: pack.directory)
        #expect(reopened.manifest == pack.manifest)
        try reopened.verify()
    }

    @Test func leavesNoPartialDirectoryBehindOnSuccess() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        _ = try OfflinePack.install(tiles: tiles, manifest: Self.manifest(for: tiles), in: root)

        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!entries.contains { $0.hasSuffix(".partial") })
    }

    @Test func refusesATruncatedDownload() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        let full = Self.manifest(for: tiles)
        // Same manifest, fewer bytes: the download stopped early.
        let truncated = tiles.prefix(tiles.count - 10)

        #expect(throws: OfflinePack.PackError.self) {
            _ = try OfflinePack.install(tiles: Data(truncated), manifest: full, in: root)
        }
        // Nothing usable was created — a half-written pack must never be
        // discoverable as a whole one.
        #expect(OfflinePack.installed(in: root).isEmpty)
    }

    @Test func refusesCorruptedBytes() throws {
        let root = try Self.makeRoot()
        var tiles = Self.fakeTiles()
        let manifest = Self.manifest(for: tiles)
        // Same length, different content: a bit flip or a botched sync.
        tiles[tiles.count - 1] = 0x00

        #expect(throws: OfflinePack.PackError.self) {
            _ = try OfflinePack.install(tiles: tiles, manifest: manifest, in: root)
        }
    }

    @Test func refusesSomethingThatIsNotPMTiles() throws {
        let root = try Self.makeRoot()
        let notTiles = Data("<!doctype html><html>404 Not Found".utf8)
        let manifest = OfflinePack.Manifest(
            tripId: "trip_tmb_ccw", tripRevision: 1, bbox: [0, 0, 1, 1],
            minZoom: 0, maxZoom: 14, byteCount: notTiles.count,
            contentHash: FNV1a.hash64(bytes: notTiles),
            source: "test", createdAt: Date()
        )
        // Size and hash both match — an error page saved verbatim would pass
        // every check except this one.
        #expect(throws: OfflinePack.PackError.notPMTiles) {
            _ = try OfflinePack.install(tiles: notTiles, manifest: manifest, in: root)
        }
    }

    @Test func refusesAnOlderPMTilesVersion() throws {
        var v2 = Data("PMTiles".utf8)
        v2.append(2)
        v2.append(Data(repeating: 0, count: 16))
        #expect(throws: OfflinePack.PackError.unsupportedPMTilesVersion(2)) {
            try OfflinePack.validatePMTilesHeader(v2)
        }
    }

    // MARK: - Trip binding

    @Test func refusesAPackCutForADifferentTrip() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        let pack = try OfflinePack.install(
            tiles: tiles, manifest: Self.manifest(for: tiles, tripId: "trip_other"), in: root
        )
        #expect(throws: OfflinePack.PackError.self) {
            _ = try OfflinePack.open(directory: pack.directory, expectedTripId: "trip_tmb_ccw")
        }
    }

    @Test func recordsTheRevisionItWasCutFor() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        let pack = try OfflinePack.install(
            tiles: tiles, manifest: Self.manifest(for: tiles, revision: 4), in: root
        )
        // A re-routed trip needs new tiles; pairing old tiles with a new route
        // silently produces a corridor that no longer contains the path.
        #expect(pack.manifest.tripRevision == 4)
    }

    @Test func listsOnlyPacksForTheRequestedTrip() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        _ = try OfflinePack.install(tiles: tiles, manifest: Self.manifest(for: tiles), in: root)
        _ = try OfflinePack.install(
            tiles: tiles, manifest: Self.manifest(for: tiles, tripId: "trip_other"), in: root
        )

        #expect(OfflinePack.installed(in: root, tripId: "trip_tmb_ccw").count == 1)
        #expect(OfflinePack.installed(in: root).count == 2)
    }

    // MARK: - Housekeeping

    @Test func sweepsAwayAbandonedPartials() throws {
        let root = try Self.makeRoot()
        // What a download killed mid-write leaves behind.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("abandoned.partial"), withIntermediateDirectories: true
        )
        #expect(OfflinePack.cleanUpPartials(in: root) == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func deletingRemovesEverything() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        let pack = try OfflinePack.install(tiles: tiles, manifest: Self.manifest(for: tiles), in: root)
        try pack.delete()
        #expect(OfflinePack.installed(in: root).isEmpty)
    }

    // MARK: - Style

    @Test func buildsAStyleThatReadsOnlyFromDisk() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        let pack = try OfflinePack.install(tiles: tiles, manifest: Self.manifest(for: tiles), in: root)

        let styleURL = try pack.makeStyle()
        let style = try JSONSerialization.jsonObject(
            with: Data(contentsOf: styleURL)
        ) as! [String: Any]

        // Every URL in the style must be local, or the map silently needs
        // signal — the one thing this whole milestone exists to avoid.
        let sources = style["sources"] as! [String: [String: Any]]
        let url = sources["protomaps"]!["url"] as! String
        #expect(url.hasPrefix("pmtiles://file://"))
        #expect(url.hasSuffix("tiles.pmtiles"))

        let glyphs = style["glyphs"] as! String
        #expect(glyphs.hasPrefix("file://"))
        #expect(glyphs.hasSuffix("/{fontstack}/{range}.pbf"))
        #expect(!JSONSerialization.isValidJSONObject(style) == false)
    }

    @Test func styleDrawsPathsAboveRoads() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        let pack = try OfflinePack.install(tiles: tiles, manifest: Self.manifest(for: tiles), in: root)
        let style = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try pack.makeStyle())
        ) as! [String: Any]
        let ids = (style["layers"] as! [[String: Any]]).map { $0["id"] as! String }

        // On a walking map the path network is the important one, whatever its
        // position in a road hierarchy designed for driving.
        let paths = try #require(ids.firstIndex(of: "paths"))
        let roads = try #require(ids.firstIndex(of: "roads"))
        #expect(paths > roads)
        #expect(ids.contains("place-labels"))
    }

    @Test func styleOnlyNamesSourceLayersThatExistInTheSchema() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        let pack = try OfflinePack.install(tiles: tiles, manifest: Self.manifest(for: tiles), in: root)
        let style = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try pack.makeStyle())
        ) as! [String: Any]

        // The Protomaps v4 vector layers, read from a real pack's metadata.
        // Naming one that does not exist is a silent failure — the layer simply
        // draws nothing — and that is exactly what happened with "natural",
        // which cost forest, rock and glacier rendering before anyone noticed.
        let known: Set<String> = [
            "boundaries", "buildings", "earth", "landcover",
            "landuse", "places", "pois", "roads", "water"
        ]
        let used = (style["layers"] as! [[String: Any]])
            .compactMap { $0["source-layer"] as? String }
        #expect(!used.isEmpty)
        for layer in used {
            #expect(known.contains(layer), "style references unknown source layer '\(layer)'")
        }
    }

    @Test func reportsMissingGlyphsWithoutRejectingThePack() throws {
        let root = try Self.makeRoot()
        let tiles = Self.fakeTiles()
        let pack = try OfflinePack.install(tiles: tiles, manifest: Self.manifest(for: tiles), in: root)
        // Geometry still renders without them; only labels disappear. That is
        // a degradation to report, not a reason to refuse the map.
        #expect(!pack.hasGlyphs)
        try FileManager.default.createDirectory(at: pack.glyphsDirectory, withIntermediateDirectories: true)
        #expect(pack.hasGlyphs)
    }
}
