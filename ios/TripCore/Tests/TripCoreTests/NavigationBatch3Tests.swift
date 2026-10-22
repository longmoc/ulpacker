import Foundation
import Testing
@testable import TripCore

/// Batch 3 of the navigation review. Each case is something a walker meets,
/// most of them found in the two field walks of 12 and 15 October: an "Off
/// route" alarm on the way to the start, a wrong turn at a right angle noticed
/// late, walking the line backwards unnoticed, distance banked while standing
/// indoors, and a motorbike ride the matcher could not keep up with.
@MainActor
struct NavigationBatch3Tests {
    static let lat0 = 45.9
    static let mLng = 111_320.0 * cos(lat0 * .pi / 180)
    static let mLat = 111_320.0

    /// A 3 km straight line heading east, a point every ~19 m.
    static func session() throws -> RecordingSession {
        let points = (0..<159).map { "[\(lat0),\(6.8 + Double($0) * 19 / mLng),1000]" }.joined(separator: ",")
        let json = """
        {"format":"ulpacker-trip-package","schemaVersion":1,"hashAlgorithm":"fnv1a64",
         "tripId":"line","revision":1,"publishedAt":"2026-01-01T00:00:00.000Z",
         "trip":{"name":"L","description":"","startName":"","finishName":"","loop":false,"startDayNumber":1},
         "plannedRoute":{"segments":[{"points":[\(points)]}],
           "stats":{"distanceM":3000,"ascentM":0,"descentM":0,"minEle":1000,"maxEle":1000,
                    "elevationCoverage":1,"pointCount":159,"segmentCount":1}},
         "checkpoints":[],"itinerary":[],"extraDays":[],
         "navigationDefaults":{"offRouteEnterM":75,"offRouteExitM":40},"contentHash":"x"}
        """
        let pkg = try JSONDecoder().decode(TripPackage.self, from: Data(json.utf8))
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b3-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try RecordingSession.start(
            package: pkg, index: RouteIndex(segments: pkg.plannedRoute.segments), in: root,
            nativeConfig: RecordingSessionTests.nativeConfig, startedAt: Date(timeIntervalSince1970: 0))
    }

    /// Feeds positions in metres east/north of the start, 15 m apart at 1.3 m/s.
    @MainActor final class Walker {
        let s: RecordingSession
        var t = 0.0
        var e: Double, n: Double
        var log: [RecordingSession.Progress] = []
        init(_ s: RecordingSession, at e: Double, _ n: Double) { self.s = s; self.e = e; self.n = n }
        @discardableResult
        func to(_ e2: Double, _ n2: Double, speed: Double = 1.3, hAcc: Double = 5) throws -> RecordingSession.Progress? {
            let d = hypot(e2 - e, n2 - n); let steps = max(1, Int((d / 15).rounded()))
            var last: RecordingSession.Progress?
            for i in 1...steps {
                let f = Double(i) / Double(steps)
                t += d / Double(steps) / speed
                last = try s.receive(lat: lat0 + (n + (n2 - n) * f) / mLat, lng: 6.8 + (e + (e2 - e) * f) / mLng,
                                     at: Date(timeIntervalSince1970: t), horizontalAccuracyM: hAcc, speed: speed)
                if let last { log.append(last) }
            }
            e = e2; n = n2
            return last
        }
        var offRouteAlerts: Int { log.filter(\.shouldAlertOffRoute).count }
        var wrongWayAlerts: Int { log.filter(\.shouldAlertWrongWay).count }
    }

    // MARK: - #9 walking to the start is not being lost

    @Test func walkingToTheRouteIsApproachNotOffRoute() throws {
        let w = Walker(try Self.session(), at: 500, 400)
        try w.to(500, 60)
        #expect(w.offRouteAlerts == 0)
        #expect(w.log.last?.offRouteState == .approaching)
        let joined = try #require(try w.to(500, 0))
        #expect(joined.offRouteState == .onRoute)
    }

    @Test func afterJoiningAWrongTurnStillAlerts() throws {
        let w = Walker(try Self.session(), at: 500, 400)
        try w.to(500, 0); try w.to(800, 0)
        try w.to(800, 300)
        #expect(w.offRouteAlerts == 1)
    }

    @Test func aPauseDoesNotForgetTheRouteWasJoined() throws {
        let s = try Self.session()
        let w = Walker(s, at: 0, 0)
        try w.to(600, 0)
        try s.pause(); s.resumeRecording(); w.t += 1_800
        try w.to(600, 300)
        #expect(w.offRouteAlerts == 1)
    }

    // MARK: - #4 a right-angle turn is noticed on travel, not on route progress

    @Test func aRightAngleDepartureAlertsWellBefore240m() throws {
        let w = Walker(try Self.session(), at: 0, 0)
        try w.to(1_000, 0)
        var walkedOff = 0.0
        while walkedOff < 300 {
            walkedOff += 15
            try w.to(1_000, walkedOff)
            if w.offRouteAlerts > 0 { break }
        }
        #expect(w.offRouteAlerts == 1)
        #expect(walkedOff <= 150, "alerted after \(Int(walkedOff)) m off the line")
    }

    // MARK: - #12 the finish ends off-route

    @Test func walkingHomeFromTheFinishIsQuiet() throws {
        let w = Walker(try Self.session(), at: 0, 0)
        try w.to(2_990, 0)
        try w.to(2_990, 300)
        #expect(w.offRouteAlerts == 0)
        #expect(w.log.last?.offRouteState == .finished)
    }

    // MARK: - #5 walking the line backwards

    @Test func walkingBackAlongTheLineIsNoticedOnce() throws {
        let w = Walker(try Self.session(), at: 0, 0)
        try w.to(1_200, 0)
        w.t += 300                       // a break
        try w.to(800, 0)                 // set off the way they came
        #expect(w.wrongWayAlerts == 1)
        #expect(w.log.last?.isWrongWay == true)
        #expect(w.log.last?.offRouteState == .onRoute)
        try w.to(860, 0)                 // turned round
        #expect(w.log.last?.isWrongWay == false)
        #expect(w.wrongWayAlerts == 1)
    }

    @Test func aFewStepsBackIsNotWrongWay() throws {
        let w = Walker(try Self.session(), at: 0, 0)
        try w.to(1_200, 0)
        try w.to(1_100, 0)               // 100 m back for a photo
        try w.to(1_400, 0)
        #expect(w.wrongWayAlerts == 0)
    }

    // MARK: - #6 coming back from no-fix does not default to "on route"

    @Test func signalBackInTheBandIsNotOnRoute() throws {
        var m = OffRouteMonitor()
        func match(_ off: Double, _ c: RouteMatcher.Confidence = .tracking) -> RouteMatcher.Match {
            .init(routeDistanceM: 500, offsetM: off, lat: 45.9, lng: 6.8, ele: nil, confidence: c, progressM: 0)
        }
        _ = m.update(match: match(2), accuracyM: 5, at: Date(timeIntervalSince1970: 0))
        _ = m.evaluate(at: Date(timeIntervalSince1970: 200))
        #expect(m.state == .noFix)
        // The replayed walk: back with the walker 85 m off and a 22 m fix —
        // inside the band, where the old code said "on route".
        let back = m.update(match: match(85), accuracyM: 22, at: Date(timeIntervalSince1970: 210))
        #expect(back.state == .suspect)
    }

    // MARK: - #11 a vehicle the receiver can measure

    @Test func aRideAlongTheRouteIsFollowedWithoutJumps() {
        let pts = (0..<200).map { TrackPoint(lat: Self.lat0, lng: 6.8 + Double($0) * 19 / Self.mLng, ele: 1000) }
        var m = RouteMatcher(index: RouteIndex(segments: [TripPackage.Segment(points: pts)]))
        var jumps = 0, worst = 0.0
        for i in 0..<40 {   // 20 m every 3 s, as the motorbike on 12 October
            let f = ActivityPackage.Fix(seq: i, t: Date(timeIntervalSince1970: Double(i) * 3),
                                        lat: Self.lat0, lng: 6.8 + Double(i) * 20 / Self.mLng, hAcc: 3, speed: 6.7)
            let r = m.match(f)
            if r.confidence == .jumped { jumps += 1 }
            if i > 0 { worst = max(worst, r.offsetM) }
        }
        #expect(jumps == 0)
        #expect(worst < 10)
    }

    // MARK: - #10 / #11 distance that was not walked

    static func fix(_ seq: Int, _ e: Double, _ t: Double, hAcc: Double, speed: Double?) -> ActivityPackage.Fix {
        .init(seq: seq, t: Date(timeIntervalSince1970: t), lat: lat0, lng: 6.8 + e / mLng, hAcc: hAcc, speed: speed)
    }

    @Test func gpsHoppingIndoorsWalksNowhere() {
        // As recorded: 33 m hops, no speed, 20–26 m accuracy, every 8 s.
        let fixes = [Self.fix(1, 0, 0, hAcc: 20, speed: nil), Self.fix(2, 33.5, 8, hAcc: 26, speed: nil),
                     Self.fix(3, 0, 16, hAcc: 20, speed: nil), Self.fix(4, 33.9, 24, hAcc: 26, speed: nil)]
        #expect(WalkedDistance.total(of: fixes, maxAccuracyM: 50) == 0)
    }

    @Test func aStepWithoutSpeedStillCountsWhenItClearlyMoved() {
        #expect(WalkedDistance.step(from: Self.fix(1, 0, 0, hAcc: 5, speed: nil),
                                    to: Self.fix(2, 40, 30, hAcc: 5, speed: nil)) > 35)
    }

    @Test func aReceiverMeasuredRideIsNotWalked() {
        // 4.5 m/s on the positions — under the implied-speed limit — but the
        // receiver measured 6.5 m/s: a motorbike in traffic.
        #expect(WalkedDistance.step(from: Self.fix(1, 0, 0, hAcc: 3, speed: 6.5),
                                    to: Self.fix(2, 13.5, 3, hAcc: 3, speed: 6.5)) == 0)
    }
}
