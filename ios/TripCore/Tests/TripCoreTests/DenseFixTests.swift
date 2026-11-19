import Foundation
import Testing
@testable import TripCore

/// Fixes every 4 s, as the watched screen's 5 m filter delivers them.
///
/// The matcher's reach is speed × elapsed. At the walking filter's 12 s that
/// is 48 m and hides how far behind the last placement may be; at 4 s it is
/// 16 m, and a corner the walker cuts by more than that used to leave the
/// cursor stuck on the bend while they walked on.
struct DenseFixTests {
    static let lat0 = 45.9, lng0 = 6.8
    static let mPerLng = 111_320.0 * cos(45.9 * .pi / 180)

    static func at(east: Double, north: Double) -> (lat: Double, lng: Double) {
        (lat0 + north / 111_320, lng0 + east / mPerLng)
    }

    /// East 80 m, then north 300 m: a bend, points every 20 m.
    static func bend() -> RouteIndex {
        var points: [TrackPoint] = []
        for e in stride(from: 0.0, through: 80, by: 20) {
            let p = at(east: e, north: 0); points.append(TrackPoint(lat: p.lat, lng: p.lng, ele: 1000))
        }
        for n in stride(from: 20.0, through: 300, by: 20) {
            let p = at(east: 80, north: n); points.append(TrackPoint(lat: p.lat, lng: p.lng, ele: 1000))
        }
        return RouteIndex(segments: [TripPackage.Segment(points: points)])
    }

    @Test func aCutCornerDoesNotStrandTheCursorWhenFixesComeEveryFourSeconds() {
        var matcher = RouteMatcher(index: Self.bend())
        // Walk the line to 50 m east, cut across to 40 m up the second leg,
        // then walk up it: 1.4 m/s, a fix every 4 s.
        var path: [(Double, Double)] = []
        for e in stride(from: 0.0, through: 50, by: 5.6) { path.append((e, 0)) }
        let cut = 50.0 // metres of diagonal
        for d in stride(from: 5.6, through: cut, by: 5.6) {
            path.append((50 + 30 * d / cut, 40 * d / cut))
        }
        for n in stride(from: 45.6, through: 200, by: 5.6) { path.append((80, n)) }

        var worstOnLeg = 0.0
        for (i, (e, n)) in path.enumerated() {
            let p = Self.at(east: e, north: n)
            let m = matcher.match(ActivityPackage.Fix(
                seq: i, t: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 4),
                lat: p.lat, lng: p.lng, hAcc: 5, speed: 1.4))
            #expect(m.confidence != .jumped, "jumped at fix \(i) (\(e), \(n))")
            if n >= 45 { worstOnLeg = max(worstOnLeg, m.offsetM) }
        }
        // Back on the line, the cursor is on it with the walker.
        #expect(worstOnLeg < 5, "offset on the second leg reached \(worstOnLeg) m")
    }
}
