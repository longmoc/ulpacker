import Foundation

/// A route prepared for repeated position queries.
///
/// Built once when a trip is opened, then hit on every GPS fix for hours.
///
/// The grid exists for **correctness, not speed**. It returns every edge within
/// a radius, which is what lets `RouteMatcher` score rival branches against each
/// other; a nearest-point scan can only ever hand back one answer, and on a
/// switchback or an out-and-back the nearest one is regularly wrong.
///
/// Measured on the real Tour du Mont Blanc route (8560 edges), the grid is
/// about five times faster than a full scan — 0.01 ms against 0.05 ms per
/// query. Both are irrelevant at one fix every thirteen seconds. An earlier
/// version of this comment justified the index on battery grounds; that was
/// wrong, and the measurement is recorded in `MatcherQualityTests` so the claim
/// stays honest. The index would start to matter on a route an order of
/// magnitude longer, or if fixes ever arrived far more often.
public struct RouteIndex: Sendable {
    /// One straight piece of the route, with where it starts along the whole
    /// route so a hit converts straight into a route distance.
    public struct Edge: Sendable {
        public let segmentIndex: Int
        public let startLat: Double
        public let startLng: Double
        public let endLat: Double
        public let endLng: Double
        public let startEle: Double?
        public let endEle: Double?
        /// Route distance at the edge's start point.
        public let routeStartM: Double
        public let lengthM: Double
    }

    public struct Projection: Sendable, Equatable {
        /// Distance along the whole route, in metres.
        public let routeDistanceM: Double
        /// Perpendicular distance from the query point to the route.
        public let offsetM: Double
        public let lat: Double
        public let lng: Double
        public let ele: Double?
        public let segmentIndex: Int
    }

    public let edges: [Edge]
    public let totalM: Double
    /// Route distance where each segment begins; a gap between segments is a
    /// real break in the line (a shuttle, a ferry), not a rendering artefact.
    public let segmentOffsets: [Double]

    /// Edges too geographically wide to grid — see the guard in `init`.
    /// Non-zero means the route contains something implausible and grid queries
    /// there are incomplete; the exhaustive path still covers them.
    public let unindexedEdgeCount: Int

    /// Roughly a 10 × 10 cell box: far beyond any real trail edge, far below
    /// the world-spanning case.
    static let maxCellsPerEdge = 100

    private let grid: [GridKey: [Int]]
    private let cellSizeDegrees: Double
    private let referenceLat: Double

    private struct GridKey: Hashable {
        let x: Int
        let y: Int
    }

    // MARK: - Build

    public init(segments: [TripPackage.Segment]) {
        var edges: [Edge] = []
        var offsets: [Double] = []
        var total = 0.0
        var latSum = 0.0
        var latCount = 0

        for (segmentIndex, segment) in segments.enumerated() {
            offsets.append(total)
            let points = segment.points
            guard points.count >= 2 else { continue }
            for i in 1..<points.count {
                let a = points[i - 1]
                let b = points[i]
                let length = ActivityJournal.haversine(a.lat, a.lng, b.lat, b.lng)
                edges.append(
                    Edge(
                        segmentIndex: segmentIndex,
                        startLat: a.lat,
                        startLng: a.lng,
                        endLat: b.lat,
                        endLng: b.lng,
                        startEle: a.ele.map(Double.init),
                        endEle: b.ele.map(Double.init),
                        routeStartM: total,
                        lengthM: length
                    )
                )
                total += length
                latSum += a.lat
                latCount += 1
            }
        }

        self.edges = edges
        self.totalM = total
        self.segmentOffsets = offsets
        self.referenceLat = latCount > 0 ? latSum / Double(latCount) : 0

        // ~500 m cells: large enough that a typical query reads one or two
        // cells, small enough that a cell on a dense switchback stays short.
        let cell = 500.0 / 111_320.0
        self.cellSizeDegrees = cell

        var grid: [GridKey: [Int]] = [:]
        var unindexed = 0
        for (index, edge) in edges.enumerated() {
            // An edge can straddle cells, so register it in every cell its
            // bounding box touches — missing one would hide it from a query
            // standing right next to it.
            let minLat = min(edge.startLat, edge.endLat)
            let maxLat = max(edge.startLat, edge.endLat)
            let minLng = min(edge.startLng, edge.endLng)
            let maxLng = max(edge.startLng, edge.endLng)
            let y0 = Int((minLat / cell).rounded(.down))
            let y1 = Int((maxLat / cell).rounded(.down))
            let x0 = Int((minLng / cell).rounded(.down))
            let x1 = Int((maxLng / cell).rounded(.down))

            // A sane trail edge spans one or two cells. A pathological one —
            // a route crossing the antimeridian, or a single corrupt
            // coordinate in an imported GPX — spans the width of the world:
            // an edge from +179.99 to -179.99 would be registered in 80,146
            // cells on its own, so a handful of them turns opening a trip into
            // a hang. Such edges stay out of the grid and remain reachable
            // through `nearestExhaustive`, which degrades the query rather than
            // the app.
            let cellsSpanned = (y1 - y0 + 1) * (x1 - x0 + 1)
            guard cellsSpanned <= Self.maxCellsPerEdge else {
                unindexed += 1
                continue
            }

            for y in y0...y1 {
                for x in x0...x1 {
                    grid[GridKey(x: x, y: y), default: []].append(index)
                }
            }
        }
        self.grid = grid
        self.unindexedEdgeCount = unindexed
    }

    // MARK: - Query

    /// Every edge within `radiusM` of the point, as candidate projections.
    ///
    /// Returns *all* of them rather than only the nearest. On a switchback or
    /// where two paths run parallel, the nearest edge is regularly the wrong
    /// one, and picking it here would leave the caller no way to recover — see
    /// `RouteMatcher`, which scores these against where the walker actually was
    /// a moment ago.
    public func candidates(lat: Double, lng: Double, radiusM: Double) -> [Projection] {
        guard !edges.isEmpty else { return [] }

        // Cells are square in *degrees*, not in metres: one cell spans 500 m of
        // latitude but only 500·cos(lat) m of longitude. Converting the radius
        // with the latitude scale in both axes therefore scans a box narrower
        // than asked for, and the further from the equator the worse it gets —
        // at 68° a "300 m" query would only reach 187 m east and west.
        //
        // The failure is quiet, which is what makes it dangerous: the query
        // returns a partial candidate set rather than nothing, and the matcher
        // picks the best of the wrong candidates.
        let metresPerDegreeLat = 111_320.0
        let metresPerDegreeLng = max(1.0, 111_320.0 * cos(lat * .pi / 180))
        let cellsY = max(1, Int((radiusM / metresPerDegreeLat / cellSizeDegrees).rounded(.up)))
        let cellsX = max(1, Int((radiusM / metresPerDegreeLng / cellSizeDegrees).rounded(.up)))

        let centreX = Int((lng / cellSizeDegrees).rounded(.down))
        let centreY = Int((lat / cellSizeDegrees).rounded(.down))

        var seen = Set<Int>()
        var found: [Projection] = []
        for dy in -cellsY...cellsY {
            for dx in -cellsX...cellsX {
                guard let bucket = grid[GridKey(x: centreX + dx, y: centreY + dy)] else { continue }
                for edgeIndex in bucket where !seen.contains(edgeIndex) {
                    seen.insert(edgeIndex)
                    let projection = project(onto: edges[edgeIndex], lat: lat, lng: lng)
                    if projection.offsetM <= radiusM { found.append(projection) }
                }
            }
        }
        return found
    }

    /// The single nearest point on the route, scanning every edge.
    ///
    /// The slow path, kept for when there is no previous position to reason
    /// from — first fix of a session, or recovery after the matcher lost track.
    public func nearestExhaustive(lat: Double, lng: Double) -> Projection? {
        var best: Projection?
        for edge in edges {
            let projection = project(onto: edge, lat: lat, lng: lng)
            if best == nil || projection.offsetM < best!.offsetM { best = projection }
        }
        return best
    }

    /// The point at a given distance along the route.
    public func position(atRouteDistance routeM: Double) -> Projection? {
        guard !edges.isEmpty else { return nil }
        let clamped = min(max(routeM, 0), totalM)
        var low = 0
        var high = edges.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if edges[mid].routeStartM <= clamped { low = mid } else { high = mid - 1 }
        }
        let edge = edges[low]
        let t = edge.lengthM > 0 ? (clamped - edge.routeStartM) / edge.lengthM : 0
        return Projection(
            routeDistanceM: clamped,
            offsetM: 0,
            lat: edge.startLat + t * (edge.endLat - edge.startLat),
            lng: edge.startLng + t * (edge.endLng - edge.startLng),
            ele: interpolatedElevation(edge, t),
            segmentIndex: edge.segmentIndex
        )
    }

    // MARK: - Geometry

    /// Equirectangular projection around the route's mean latitude, matching
    /// `projectOntoEdge` in trail.js. Good to well under a metre over the few
    /// hundred metres that matter here, and far cheaper than a great-circle
    /// solve on every edge of every fix.
    func project(onto edge: Edge, lat: Double, lng: Double) -> Projection {
        let mPerLat = 111_320.0
        let mPerLng = 111_320.0 * cos(referenceLat * .pi / 180)

        let ax = edge.startLng * mPerLng
        let ay = edge.startLat * mPerLat
        let bx = edge.endLng * mPerLng
        let by = edge.endLat * mPerLat
        let px = lng * mPerLng
        let py = lat * mPerLat

        let dx = bx - ax
        let dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        var t = lengthSquared == 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / lengthSquared
        t = min(max(t, 0), 1)

        let sx = ax + t * dx
        let sy = ay + t * dy

        return Projection(
            routeDistanceM: edge.routeStartM + t * edge.lengthM,
            offsetM: hypot(px - sx, py - sy),
            lat: edge.startLat + t * (edge.endLat - edge.startLat),
            lng: edge.startLng + t * (edge.endLng - edge.startLng),
            ele: interpolatedElevation(edge, t),
            segmentIndex: edge.segmentIndex
        )
    }

    private func interpolatedElevation(_ edge: Edge, _ t: Double) -> Double? {
        if let start = edge.startEle, let end = edge.endEle { return start + t * (end - start) }
        return edge.startEle ?? edge.endEle
    }
}
