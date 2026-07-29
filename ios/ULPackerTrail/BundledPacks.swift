import Foundation
import TripCore

/// Offline map packs that ship inside the app.
///
/// A pack reached this phone by cable and a `devicectl` command, which is fine
/// for the person holding the cable and leaves anyone else with a map that
/// falls back to a schematic world basemap over the network — the opposite of
/// what the app is for. Shipping one region inside the build means installing
/// it is the whole setup.
///
/// The files travel flattened, because they have to. Xcode's synchronised
/// folder group copies resources into the bundle root without their
/// directories, so `glyphs/Noto Sans Regular/0-255.pbf` and
/// `glyphs/Noto Sans Medium/0-255.pbf` arrive as two files with one name and
/// the build fails outright. They are named apart on the way in and put back
/// together here.
enum BundledPacks {
    /// Restore every bundled pack into the writable packs directory.
    ///
    /// Idempotent and cheap after the first run: a pack whose directory already
    /// exists is left alone, so this can be called at every launch. Copying
    /// rather than reading in place is not laziness — `makeStyle()` writes a
    /// `style.json` beside the tiles, and the bundle is read-only.
    @MainActor
    static func install(into root: URL = RouteMapView.packsRoot) {
        for manifest in Bundle.main.urls(
            forResourcesWithExtension: "manifest.json", subdirectory: nil
        ) ?? [] {
            let name = manifest.lastPathComponent
                .replacingOccurrences(of: ".manifest.json", with: "")
            let destination = root.appendingPathComponent(name, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            do {
                try install(name: name, manifest: manifest, into: destination)
            } catch {
                // A pack that fails to unpack is a map that falls back online,
                // not a walk that cannot happen. Clear the half-made directory
                // so the next launch tries again rather than finding a
                // convincing-looking ruin.
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    private static func install(name: String, manifest: URL, into destination: URL) throws {
        guard let tiles = Bundle.main.url(forResource: "\(name).tiles", withExtension: "pmtiles")
        else { throw CocoaError(.fileNoSuchFile) }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: tiles, to: destination.appendingPathComponent("tiles.pmtiles")
        )
        try FileManager.default.copyItem(
            at: manifest, to: destination.appendingPathComponent("manifest.json")
        )

        // Glyphs are the same for every pack — one font, three ranges — so they
        // ship once and are copied into each.
        let glyphs = destination.appendingPathComponent("glyphs", isDirectory: true)
        for url in Bundle.main.urls(forResourcesWithExtension: "pbf", subdirectory: nil) ?? [] {
            let file = url.lastPathComponent
            guard file.hasPrefix("glyph-") else { continue }
            // `glyph-Noto_Sans_Regular-0-255.pbf` → `Noto Sans Regular/0-255.pbf`
            let body = file.dropFirst("glyph-".count).replacingOccurrences(of: ".pbf", with: "")
            // Split on the *first* hyphen: the font name has none, having had
            // its spaces turned into underscores, while the range is "0-255"
            // and splitting from the other end cuts it in half.
            guard let split = body.range(of: "-") else { continue }
            let font = body[..<split.lowerBound].replacingOccurrences(of: "_", with: " ")
            let range = String(body[split.upperBound...])

            let fontDirectory = glyphs.appendingPathComponent(font, isDirectory: true)
            try FileManager.default.createDirectory(
                at: fontDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: url, to: fontDirectory.appendingPathComponent("\(range).pbf")
            )
        }

        // Nothing is trusted because it came from the bundle: a truncated copy
        // is exactly what `verify()` exists to catch, and a pack that cannot be
        // opened must not be left looking installed.
        try OfflinePack.open(directory: destination).verify()

        // `verify()` checks the tiles and says nothing about glyphs, so a pack
        // can pass it and still draw no labels at all — which is what happened
        // when the font name was split off the wrong end of the filename and
        // every range landed in a directory of its own. Ask for the exact path
        // the style will ask for.
        let expected = glyphs
            .appendingPathComponent(OfflineStyle.labelFont, isDirectory: true)
            .appendingPathComponent("0-255.pbf")
        guard FileManager.default.fileExists(atPath: expected.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
    }
}
