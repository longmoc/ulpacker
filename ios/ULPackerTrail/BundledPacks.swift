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

        // No glyphs here: they are shared by every pack — see `BundledGlyphs`.

        // Nothing is trusted because it came from the bundle: a truncated copy
        // is exactly what `verify()` exists to catch, and a pack that cannot be
        // opened must not be left looking installed.
        try OfflinePack.open(directory: destination).verify()
    }
}

/// One complete glyph set for the whole app, shared by every map pack.
///
/// Packs used to carry their own glyphs — three ranges of "Noto Sans Regular",
/// enough for the Alps. MapLibre, asked for a range that is not there, does not
/// just skip those characters: it abandons the entire tile whose labels needed
/// them, so any tile over Hanoi naming a place in Vietnamese drew nothing at
/// all. All 256 ranges now ship once in the bundle (7 MB; most are 29-byte
/// empty files, which load cleanly and draw nothing, as they should), and every
/// pack's style points here. Packs already on a phone are fixed by this
/// without being re-cut or re-pushed.
///
/// Flattened in the bundle like the pack files (`glyph-Noto_Sans_Regular-
/// 7680-7935.pbf`) and restored to `<font>/<range>.pbf` in Library — not
/// Application Support, whose space would sit inside the glyph URL.
enum BundledGlyphs {
    /// Bump when the bundled set changes, so phones re-copy it.
    static let version = "noto-sans-regular/protomaps-basemaps-assets/256/v1"

    static var directory: URL {
        URL.libraryDirectory.appendingPathComponent("glyphs", isDirectory: true)
    }

    private static var marker: URL { directory.appendingPathComponent(".version") }

    /// The shared directory, installing it first if needed; nil if that fails,
    /// in which case a pack falls back to its own (partial) glyphs.
    @MainActor
    static func ensureInstalled() -> URL? {
        if (try? String(contentsOf: marker, encoding: .utf8)) == version { return directory }
        do {
            try install()
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private static func install() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        let font = OfflineStyle.labelFont
        let fontDirectory = directory.appendingPathComponent(font, isDirectory: true)
        try fm.createDirectory(at: fontDirectory, withIntermediateDirectories: true)

        let prefix = "glyph-" + font.replacingOccurrences(of: " ", with: "_") + "-"
        for range in OfflineStyle.glyphRanges {
            guard let source = Bundle.main.url(forResource: prefix + range, withExtension: "pbf")
            else { throw CocoaError(.fileNoSuchFile) }
            try fm.copyItem(at: source, to: fontDirectory.appendingPathComponent("\(range).pbf"))
        }
        // Written last: present only when every range is.
        try version.write(to: marker, atomically: true, encoding: .utf8)
    }
}
