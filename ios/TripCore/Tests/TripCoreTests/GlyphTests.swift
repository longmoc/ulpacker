import Foundation
import Testing
@testable import TripCore

/// The glyph contract. A range MapLibre asks for and cannot load costs the
/// whole tile — every road and building in it — so the app ships all of them
/// and every style must point at that complete set.
struct GlyphTests {
    @Test func everyRangeIsListedOnce() {
        let ranges = OfflineStyle.glyphRanges
        #expect(ranges.count == 256)
        #expect(Set(ranges).count == 256)
        #expect(ranges.first == "0-255")
        #expect(ranges.last == "65280-65535")
        // The one whose absence blanked Hanoi.
        #expect(ranges.contains("7680-7935"))
    }

    @Test func aPackStyleUsesTheSharedGlyphsWhenGiven() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("glyph-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tiles = OfflinePackTests.fakeTiles()
        let pack = try OfflinePack.install(tiles: tiles, manifest: OfflinePackTests.manifest(for: tiles), in: root)
        let shared = URL(fileURLWithPath: "/shared/glyphs", isDirectory: true)

        let style = try JSONSerialization.jsonObject(with: Data(contentsOf: pack.makeStyle(glyphsDirectory: shared))) as? [String: Any]
        #expect((style?["glyphs"] as? String)?.hasPrefix("file:///shared/glyphs/") == true)

        let own = try JSONSerialization.jsonObject(with: Data(contentsOf: pack.makeStyle())) as? [String: Any]
        #expect((own?["glyphs"] as? String)?.contains(pack.directory.lastPathComponent) == true)
    }

    @Test func theEmptyStyleCarriesGlyphsForTheAppsOwnLabels() throws {
        let shared = URL(fileURLWithPath: "/shared/glyphs", isDirectory: true)
        let style = try JSONSerialization.jsonObject(with: OfflineStyle.emptyJSON(glyphsDirectory: shared)) as? [String: Any]
        #expect((style?["glyphs"] as? String)?.hasPrefix("file:///shared/glyphs/") == true)
    }

    /// The bundled set, checked against the list: every range present, for the
    /// one font the styles name. Reads the repo, like the golden fixtures.
    @Test func theBundleShipsEveryRange() throws {
        let packs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ULPackerTrail/OfflinePacks")
        let prefix = "glyph-" + OfflineStyle.labelFont.replacingOccurrences(of: " ", with: "_") + "-"
        let missing = OfflineStyle.glyphRanges.filter {
            !FileManager.default.fileExists(atPath: packs.appendingPathComponent(prefix + $0 + ".pbf").path)
        }
        #expect(missing.isEmpty, "missing \(missing.count) ranges, e.g. \(missing.prefix(3))")
    }
}
