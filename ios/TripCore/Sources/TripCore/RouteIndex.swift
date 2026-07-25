import Foundation

/// A route prepared for repeated position queries.
///
/// Built once when a trip is opened, then hit on every GPS fix for hours. That
/// asymmetry is the whole design: `trail.js` scans every edge twice per call,
/// which is fine for a click in the planner but would be ~100k projections per
/// fix here — CPU burning in a pocket, against the project's first priority.
///
/// So edges go into a uniform grid keyed by latitude/longitude cell. A query
/// touches only the cells within its search radius, which on the Tour du Mont
/// Blanc is a few dozen edges instead of 8560.
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
        for (index, edge) in edges.enumerated() {
            // An edge can straddle cells, so register it in every cell its
            // bounding box touches — missing one would hide it from a query
            // standing right next to it.
            let minLat = min(edge.startLat, edge.endLat)
            let maxLat = max(edge.startLat, edge.endLat)
            let minLng = min(edge.startLng, edge.endLng)
            let maxLng = max(edge.startLng, edge.endLng)
            for y in Int((minLat / cell).rounded(.down))...Int((maxLat / cell).rounded(.down)) {
                for x in Int((minLng / cell).rounded(.down))...Int((maxLng / cell).rounded(.down)) {
                    grid[GridKey(x: x, y: y), default: []].append(index)
                }
            }
        }
        self.grid = grid
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
        let cellsToScan = max(1, Int((radiusM / 111_320.0 / cellSizeDegrees).rounded(.up)))
        let centreX = Int((lng / cellSizeDegrees).rounded(.down))
        let centreY = Int((lat / cellSizeDegrees).rounded(.down))

        var seen = Set<Int>()
        var found: [Projection] = []
        for dy in -cellsToScan...cellsToScan {
            for dx in -cellsToScan...cellsToScan {
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
