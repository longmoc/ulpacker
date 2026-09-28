import Foundation
import Testing
@testable import TripCore

/// Batch 2 of the navigation review: what a stop does to the cursor, and how
/// the two ends of a closed loop are told apart. Both found by replaying a real
/// walk: a thirteen-minute stop moved the cursor 1.5 km onto the other leg of a
/// route that comes back near itself, and the loop's start and finish were
/// chosen between by the order the index happened to return them.
@MainActor
struct StopsAndLoopsTests {
    static let lat0 = 45.9
    static let mLng = 111_320.0 * cos(lat0 * .pi / 180)
    static let mLat = 111_320.0

    static func ll(_ east: Double, _ north: Double) -> (lat: Double, lng: Double) {
        (lat0 + north / mLat, 6.8 + east / mLng)
    }

    /// A polyline through the given corners, a point every ~19 m.
    static func index(_ corners: [(Double, Double)]) -> (RouteIndex, [TrackPoint]) {
        var pts: [TrackPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let len = hypot(b.0 - a.0, b.1 - a.1)
            let n = max(1, Int(len / 19))
            for i in 0..<n {
                let f = Double(i) / Double(n)
                let p = ll(a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f)
                pts.append(TrackPoint(lat: p.lat, lng: p.lng, ele: 1000))
            }
        }
        let end = ll(corners.last!.0, corners.last!.1)
        pts.append(TrackPoint(lat: end.lat, lng: end.lng, ele: 1000))
        return (RouteIndex(segments: [TripPackage.Segment(points: pts)]), pts)
    }

    static func fix(_ seq: Int, _ east: Double, _ north: Double, at t: Double, hAcc: Double = 5) -> ActivityPackage.Fix {
        let p = ll(east, north)
        return .init(seq: seq, t: Date(timeIntervalSince1970: t), lat: p.lat, lng: p.lng, hAcc: hAcc, speed: 1.3)
    }

    /// Out 1 km east, 60 m north, back 1 km west: two legs 60 m apart, the
    /// shape of the replayed walk where the start and finish sections run close.
    static let uRoute = [(0.0, 0.0), (1000.0, 0.0), (1000.0, 60.0), (0.0, 60.0)]

    // MARK: - A stop is not progress (issue 1)

    @Test func aStopBetweenTwoLegsDoesNotMoveTheCursorOntoTheOther() {
        let (index, _) = Self.index(Self.uRoute)
        var m = RouteMatcher(index: index)
        var t = 0.0, seq = 0
        var east = 0.0
        while east <= 500 { seq += 1; _ = m.match(Self.fix(seq, east, 0, at: t)); east += 15; t += 15 / 1.3 }
        // Drift off to halfway between the legs — 30 m from each, as the real
        // walker was 82 m from one and 83 m from the other.
        seq += 1; _ = m.match(Self.fix(seq, 500, 30, at: t))
        let before = m.currentRouteDistanceM ?? 0
        // Thirteen minutes standing there, then one fix a few metres on.
        seq += 1
        let after = m.match(Self.fix(seq, 505, 30, at: t + 780))
        #expect(before < 1_000)
        // The other leg sits at ~1,555 m. Time alone used to "expect" 936 m of
        // progress and hand the walker to it.
        #expect(after.routeDistanceM < 1_000, "cursor moved to \(Int(after.routeDistanceM)) m while standing still")
    }

    @Test func walkingOnAfterTheStopStillTracks() {
        // The bound must not stop genuine progress after a stop.
        let (index, _) = Self.index(Self.uRoute)
        var m = RouteMatcher(index: index)
        var t = 0.0, seq = 0, east = 0.0
        while east <= 500 { seq += 1; _ = m.match(Self.fix(seq, east, 0, at: t)); east += 15; t += 15 / 1.3 }
        t += 780
        var last: RouteMatcher.Match?
        while east <= 800 { seq += 1; last = m.match(Self.fix(seq, east, 0, at: t)); east += 15; t += 15 / 1.3 }
        let final = try! #require(last)
        #expect(abs(final.routeDistanceM - 795) < 30)
        #expect(final.confidence == .tracking)
    }

    @Test func anHourPausedBetweenTheLegsResumesWhereItWas() throws {
        // The same through a real session: Pause, lunch, Resume on the spot.
        let (index, pts) = Self.index(Self.uRoute)
        let json = """
        {"format":"ulpacker-trip-package","schemaVersion":1,"hashAlgorithm":"fnv1a64",
         "tripId":"u","revision":1,"publishedAt":"2026-01-01T00:00:00.000Z",
         "trip":{"name":"U","description":"","startName":"","finishName":"","loop":false,"startDayNumber":1},
         "plannedRoute":{"segments":[{"points":[\(pts.map { "[\($0.lat),\($0.lng),1000]" }.joined(separator: ","))]}],
           "stats":{"distanceM":2060,"ascentM":0,"descentM":0,"minEle":1000,"maxEle":1000,
                    "elevationCoverage":1,"pointCount":\(pts.count),"segmentCount":1}},
         "checkpoints":[],"itinerary":[],"extraDays":[],
         "navigationDefaults":{"offRouteEnterM":75,"offRouteExitM":40},"contentHash":"x"}
        """
        let pkg = try JSONDecoder().decode(TripPackage.self, from: Data(json.utf8))
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("stops-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let s = try RecordingSession.start(package: pkg, index: index, in: root,
                                           nativeConfig: RecordingSessionTests.nativeConfig,
                                           startedAt: Date(timeIntervalSince1970: 0))
        func send(_ e: Double, _ n: Double, _ t: Double) throws -> RecordingSession.Progress? {
            let p = Self.ll(e, n)
            return try s.receive(lat: p.lat, lng: p.lng, at: Date(timeIntervalSince1970: t), horizontalAccuracyM: 5, speed: 1.3)
        }
        var t = 0.0, east = 0.0
        while east <= 500 { _ = try send(east, 0, t); east += 15; t += 15 / 1.3 }
        _ = try send(500, 30, t)
        try s.pause()
        s.resumeRecording()
        let p = try #require(try send(505, 30, t + 3_600))
        // An hour used to expect 4.3 km of progress.
        #expect(p.routeDistanceM < 1_000, "resumed at \(Int(p.routeDistanceM)) m")
    }

    // MARK: - The two ends of a closed loop (issue 8)

    /// A 500 m square: east, north, west, then south back to where it began.
    static let square = [(0.0, 0.0), (500.0, 0.0), (500.0, 500.0), (0.0, 500.0), (0.0, 0.0)]

    @Test func aFreshStartAtTheSeamIsTheStartEvenWhenTheFinishIsNearer() {
        let (index, _) = Self.index(Self.square)
        var m = RouteMatcher(index: index)
        // 2 m from the finish leg, 2.2 m from the start leg: geometry says
        // "finished". Nobody has finished a loop they have not begun.
        let match = m.match(Self.fix(1, -2, 1, at: 0))
        #expect(match.routeDistanceM < 500, "read \(Int(match.routeDistanceM)) m at the start line")
    }

    @Test func arrivingAtTheSeamAfterMostOfTheLoopIsTheFinish() {
        let (index, _) = Self.index(Self.square)
        var m = RouteMatcher(index: index)
        // Been round to 65 %, on the west leg; then cut across to the seam.
        let at = Self.ll(200, 500)
        m.seed(routeDistanceM: 1_300, at: Date(timeIntervalSince1970: 0), lat: at.lat, lng: at.lng)
        // Here the start leg is the nearer one — 2 m against 2.2 m.
        let match = m.match(Self.fix(1, 1, -2, at: 60))
        #expect(match.routeDistanceM > 1_500, "read \(Int(match.routeDistanceM)) m after walking 65 % of the loop")
    }

    @Test func arrivingAtTheSeamEarlyIsStillTheStart() {
        // The replayed walk: 17 % round, then a shortcut back to the start line.
        let (index, _) = Self.index(Self.square)
        var m = RouteMatcher(index: index)
        let at = Self.ll(300, 0)
        m.seed(routeDistanceM: 300, at: Date(timeIntervalSince1970: 0), lat: at.lat, lng: at.lng)
        // The finish leg nearer, 2 m against 2.2 m.
        let match = m.match(Self.fix(1, -2, 1, at: 400))
        #expect(match.routeDistanceM < 500, "read \(Int(match.routeDistanceM)) m after only 17 % of the loop")
    }
}
