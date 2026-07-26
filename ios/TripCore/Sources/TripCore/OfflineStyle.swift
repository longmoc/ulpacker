import Foundation

/// Builds a MapLibre style that reads entirely from a local pack.
///
/// Generated at runtime rather than shipped as a file because every URL in it
/// is absolute and container-specific: iOS rewrites the app's data directory
/// path on install and on restore, so a style written once would point at a
/// directory that no longer exists.
///
/// The layer set is chosen for walking, not for a city map. Roads are present
/// mainly as landmarks; what matters is water, landcover and the path network,
/// so paths are drawn at a width that survives a glance rather than at their
/// true hierarchy position under motorways.
///
/// Source layer names follow the Protomaps basemap v4 schema.
public enum OfflineStyle {
    /// Colours tuned for daylight on a bright screen outdoors, where subtle
    /// low-contrast palettes disappear entirely.
    private enum Palette {
        static let earth = "#f6f3ee"
        static let water = "#a8cfe8"
        static let wood = "#d5e3cd"
        static let grass = "#e3ecd8"
        static let rock = "#e6e2dc"
        static let glacier = "#e9f2f7"
        static let road = "#ffffff"
        static let roadCasing = "#ded9d2"
        static let path = "#b06a3b"
        static let building = "#e4ded4"
        static let label = "#4a4640"
        static let labelHalo = "#ffffff"
    }

    /// - Parameters:
    ///   - tilesURL: the pack's `tiles.pmtiles` on disk.
    ///   - glyphsDirectory: directory holding `<fontstack>/<range>.pbf`.
    /// The font every label on this map is drawn in, on the basemap and in the
    /// app's own layers alike.
    ///
    /// Two rules, both learned the same silent way — no error, no warning, the
    /// text simply never appears:
    ///
    ///   * A symbol layer must name its font. Left unset it asks for the SDK's
    ///     default stack, which no pack ships glyphs for.
    ///   * Name exactly one, never a fallback list. `{fontstack}` in the glyph
    ///     URL is the whole array joined into a single path component, so two
    ///     names ask for a directory that cannot exist.
    ///
    /// Keeping the app on the same font the style declares means any pack whose
    /// place names render can render the trip's stops too.
    public static let labelFont = "Noto Sans Regular"

    public static func json(tilesURL: URL, glyphsDirectory: URL) throws -> Data {
        let style: [String: Any] = [
            "version": 8,
            "name": "ULPacker Offline",
            // MapLibre substitutes {fontstack} and {range}; a file URL keeps
            // label rendering working with no network at all. Without glyphs
            // every label vanishes — including the app's own checkpoint names.
            "glyphs": "\(glyphsDirectory.absoluteString)/{fontstack}/{range}.pbf",
            "sources": [
                "protomaps": [
                    "type": "vector",
                    "url": "pmtiles://\(tilesURL.absoluteString)",
                    "attribution": "© OpenStreetMap contributors, © Protomaps"
                ]
            ],
            "layers": layers()
        ]
        return try JSONSerialization.data(withJSONObject: style, options: [.sortedKeys])
    }

    private static func layers() -> [[String: Any]] {
        var layers: [[String: Any]] = []

        layers.append([
            "id": "background", "type": "background",
            "paint": ["background-color": Palette.earth]
        ])
        layers.append(fill("earth", source: "earth", colour: Palette.earth))

        // Landcover, coarse to fine. Woodland matters to a walker: it is where
        // the GPS degrades and where the path is hardest to see.
        //
        // The source layer is `landcover`, not `natural`. An earlier version
        // used the latter, which does not exist in the Protomaps v4 schema — so
        // forest, rock and ice silently rendered nothing at all. A style that
        // names a missing layer fails quietly, which is why this is pinned by a
        // test against the real pack's metadata.
        layers.append(fill("landuse", source: "landuse", colour: Palette.grass))
        layers.append(fill(
            "landcover-wood", source: "landcover", colour: Palette.wood,
            filter: ["in", ["get", "kind"], ["literal", ["forest", "wood", "scrub"]]]
        ))
        layers.append(fill(
            "landcover-barren", source: "landcover", colour: Palette.rock,
            filter: ["in", ["get", "kind"], ["literal", ["barren", "bare_rock", "scree", "sand"]]]
        ))
        // Ice reads as pale blue-white, never as lake blue: on a mountain map
        // the difference between a glacier and standing water is not cosmetic.
        layers.append(fill(
            "landcover-glacier", source: "landcover", colour: Palette.glacier,
            filter: ["in", ["get", "kind"], ["literal", ["glacier", "ice"]]]
        ))
        // Polygons only. The `water` layer carries rivers and streams as lines
        // as well as lakes as areas — it has a `bridge` attribute, which only
        // makes sense for a line — and asking MapLibre to fill a line produces
        // long straight wedges fanning across the hillside. On a walking map
        // that reads as standing water where there is none.
        layers.append(fill(
            "water", source: "water", colour: Palette.water,
            filter: ["all",
                     ["==", ["geometry-type"], "Polygon"],
                     ["!", ["in", ["get", "kind"], ["literal", ["glacier", "ice"]]]]]
        ))
        // …and the linear watercourses drawn as what they are. Streams are
        // worth showing: they are where the water is, and a valley bottom is
        // often the way out.
        layers.append([
            "id": "waterways", "type": "line", "source": "protomaps", "source-layer": "water",
            "filter": ["==", ["geometry-type"], "LineString"],
            "paint": [
                "line-color": Palette.water,
                "line-width": ["interpolate", ["linear"], ["zoom"], 11, 0.5, 16, 2.5]
            ]
        ])

        layers.append([
            "id": "roads-casing", "type": "line", "source": "protomaps", "source-layer": "roads",
            "filter": ["!=", ["get", "kind"], "path"],
            "paint": [
                "line-color": Palette.roadCasing,
                "line-width": ["interpolate", ["linear"], ["zoom"], 10, 1.5, 16, 6]
            ]
        ])
        layers.append([
            "id": "roads", "type": "line", "source": "protomaps", "source-layer": "roads",
            "filter": ["!=", ["get", "kind"], "path"],
            "paint": [
                "line-color": Palette.road,
                "line-width": ["interpolate", ["linear"], ["zoom"], 10, 0.8, 16, 4]
            ]
        ])
        // Dashed and brown, the convention every paper walking map uses, and
        // drawn above roads because on this map it is the important network.
        layers.append([
            "id": "paths", "type": "line", "source": "protomaps", "source-layer": "roads",
            "filter": ["==", ["get", "kind"], "path"],
            "paint": [
                "line-color": Palette.path,
                "line-width": ["interpolate", ["linear"], ["zoom"], 12, 0.8, 16, 2.2],
                "line-dasharray": [2, 1.5],
                "line-opacity": 0.85
            ]
        ])

        layers.append([
            "id": "buildings", "type": "fill", "source": "protomaps", "source-layer": "buildings",
            "paint": ["fill-color": Palette.building]
        ])

        layers.append([
            "id": "place-labels", "type": "symbol", "source": "protomaps", "source-layer": "places",
            "layout": [
                "text-field": ["get", "name"],
                "text-font": [labelFont],
                "text-size": ["interpolate", ["linear"], ["zoom"], 8, 10, 14, 14],
                "text-max-width": 8
            ],
            "paint": [
                "text-color": Palette.label,
                "text-halo-color": Palette.labelHalo,
                "text-halo-width": 1.5
            ]
        ])

        return layers
    }

    private static func fill(
        _ id: String, source: String, colour: String, filter: Any? = nil
    ) -> [String: Any] {
        var layer: [String: Any] = [
            "id": id, "type": "fill", "source": "protomaps", "source-layer": source,
            "paint": ["fill-color": colour]
        ]
        if let filter { layer["filter"] = filter }
        return layer
    }
}

extension OfflinePack {
    var glyphsDirectory: URL { directory.appendingPathComponent("glyphs", isDirectory: true) }
    private var styleURL: URL { directory.appendingPathComponent("style.json") }

    /// Whether this pack carries the glyphs its labels need. A pack without
    /// them still draws geometry, so this is a degradation to report, not a
    /// reason to refuse the pack.
    public var hasGlyphs: Bool {
        FileManager.default.fileExists(atPath: glyphsDirectory.path)
    }

    /// Write the style beside the tiles and return its URL, ready for
    /// MapLibre's `styleURL`. Rewritten on every call because the container
    /// path it embeds changes between installs.
    public func makeStyle() throws -> URL {
        let data = try OfflineStyle.json(tilesURL: tilesURL, glyphsDirectory: glyphsDirectory)
        try data.write(to: styleURL, options: .atomic)
        return styleURL
    }
}
