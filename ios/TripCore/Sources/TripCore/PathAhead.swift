import Foundation

/// The next few hundred metres of the route, drawn the way the walker faces.
///
/// Not directions — the route carries no junctions, so "turn left" would be a
/// guess, and on a zigzag up a col a stream of them. Just the shape of the path
/// ahead, turned so the way the route runs at the walker's position points up.
/// A bend to the left reads as a line curving left, and a walker off the route
/// shows as a dot beside the line, which answers "which way back" as well.
///
/// Up is the route's own direction, not the compass: no magnetometer to power,
/// and a picture that does not spin when the walker turns round or stands still.
public struct PathAhead: Codable, Hashable, Sendable {
    /// Metres right of and ahead of the walker's place on the route.
    public struct Point: Codable, Hashable, Sendable {
        public let x: Int
        public let y: Int

        public init(x: Int, y: Int) {
            self.x = x
            self.y = y
        }
    }

    /// The route from a little behind to `aheadM` in front; the walker's place
    /// on it is the origin.
    public let points: [Point]
    /// Where the receiver puts the walker, which is off the origin when off
    /// the route.
    public let walker: Point
    /// The next stop, when it falls within the stretch drawn.
    public let stop: Point?

    /// How far ahead is drawn: a few minutes' walking, enough to see the next
    /// bend coming without shrinking it to nothing on a lock screen.
    public static let aheadM = 500.0
    /// A little of the route behind, so the walker stands on a line rather
    /// than at the end of one.
    public static let behindM = 60.0
    /// One point every this many metres: about thirty points, small enough to
    /// send to the lock screen every update, fine enough for a switchback.
    public static let stepM = 20.0
    /// The direction is taken over this distance, so one kink in the route
    /// does not swing the whole picture.
    static let directionM = 40.0

    public init(points: [Point], walker: Point, stop: Point?) {
        self.points = points
        self.walker = walker
        self.stop = stop
    }

    public static func make(
        index: RouteIndex,
        routeM: Double,
        fix: (lat: Double, lng: Double),
        stopAtM: Double? = nil
    ) -> PathAhead? {
        let total = index.totalM
        guard total > 0, let origin = index.position(atRouteDistance: routeM) else { return nil }

        // Forward from here if there is room, otherwise along the last stretch.
        let from = min(routeM, max(0, total - directionM))
        guard let a = index.position(atRouteDistance: from),
              let b = index.position(atRouteDistance: min(total, from + directionM))
        else { return nil }
        let heading = TripPackage.bearing(fromLat: a.lat, fromLng: a.lng, toLat: b.lat, toLng: b.lng)

        let frame = Frame(lat: origin.lat, lng: origin.lng, heading: heading)
        var points: [Point] = []
        var m = max(0, routeM - behindM)
        let end = min(total, routeM + aheadM)
        while m < end {
            if let p = index.position(atRouteDistance: m) { points.append(frame.point(p.lat, p.lng)) }
            m += stepM
        }
        if let p = index.position(atRouteDistance: end) { points.append(frame.point(p.lat, p.lng)) }

        var stop: Point?
        if let stopAtM, stopAtM >= routeM, stopAtM <= end, let p = index.position(atRouteDistance: stopAtM) {
            stop = frame.point(p.lat, p.lng)
        }
        return PathAhead(points: points, walker: frame.point(fix.lat, fix.lng), stop: stop)
    }

    /// Metres east and north of an origin, turned so `heading` points up.
    private struct Frame {
        let lat: Double
        let lng: Double
        let sinH: Double
        let cosH: Double
        let metresPerDegreeLng: Double

        init(lat: Double, lng: Double, heading: Double) {
            self.lat = lat
            self.lng = lng
            let h = heading * .pi / 180
            sinH = sin(h)
            cosH = cos(h)
            metresPerDegreeLng = 111_320 * cos(lat * .pi / 180)
        }

        func point(_ pLat: Double, _ pLng: Double) -> Point {
            let east = (pLng - lng) * metresPerDegreeLng
            let north = (pLat - lat) * 111_320
            let ahead = east * sinH + north * cosH
            let right = east * cosH - north * sinH
            return Point(x: Int(right.rounded()), y: Int(ahead.rounded()))
        }
    }
}
