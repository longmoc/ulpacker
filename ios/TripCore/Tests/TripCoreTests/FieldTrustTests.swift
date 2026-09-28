import Foundation
import Testing
@testable import TripCore

/// Silence and distance — the two things the app used to mistake for a lost
/// signal. Each case here was found by replaying a real walk or a field
/// scenario against the code, not by reading it: a stop for a photo raised
/// "No GPS fix", a walk to the trailhead did the same, and one weak fix under
/// trees turned the screen red with "Not on this route".
@MainActor
struct FieldTrustTests {
    // A 6 km straight line heading east, a point every ~19 m (real density).
    static let lat0 = 45.9
    static let mLng = 111_320.0 * cos(lat0 * .pi / 180)
    static let mLat = 111_320.0

    static func package() throws -> TripPackage {
        let points = (0..<316).map { "[\(lat0),\(6.8 + Double($0) * 19 / mLng),1000]" }.joined(separator: ",")
        let json = """
        {"format":"ulpacker-trip-package","schemaVersion":1,"hashAlgorithm":"fnv1a64",
         "tripId":"straight","revision":1,"publishedAt":"2026-01-01T00:00:00.000Z",
         "trip":{"name":"S","description":"","startName":"","finishName":"","loop":false,"startDayNumber":1},
         "plannedRoute":{"segments":[{"points":[\(points)]}],
           "stats":{"distanceM":6000,"ascentM":0,"descentM":0,"minEle":1000,"maxEle":1000,
                    "elevationCoverage":1,"pointCount":316,"segmentCount":1}},
         "checkpoints":[],"itinerary":[],"extraDays":[],
         "navigationDefaults":{"offRouteEnterM":75,"offRouteExitM":40},"contentHash":"x"}
        """
        return try JSONDecoder().decode(TripPackage.self, from: Data(json.utf8))
    }

    /// A session with a walk already under way: on the line, 0 → 600 m.
    static func walking() throws -> (RecordingSession, clock: Double) {
        let pkg = try package()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("field-trust-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = try RecordingSession.start(
            package: pkg, index: RouteIndex(segments: pkg.plannedRoute.segments), in: root,
            nativeConfig: RecordingSessionTests.nativeConfig, startedAt: Date(timeIntervalSince1970: 0))
        var t = 0.0, east = 0.0
        while east <= 600 {
            try send(session, east, 0, at: t)
            east += 15; t += 15 / 1.3   // distance filter 15 m at 1.3 m/s
        }
        return (session, t)
    }

    @discardableResult
    static func send(_ s: RecordingSession, _ east: Double, _ north: Double, at t: Double,
                     hAcc: Double = 5, speed: Double? = 1.3) throws -> RecordingSession.Progress? {
        try s.receive(lat: lat0 + north / mLat, lng: 6.8 + east / mLng,
                      at: Date(timeIntervalSince1970: t), horizontalAccuracyM: hAcc, speed: speed, bearing: 90)
    }

    // MARK: - Standing still is not losing the sky

    @Test func aStopIsProbedNotAlarmed() throws {
        // The replayed walk: thirteen minutes stopped, GPS perfectly fine. The
        // app probes after a minute of silence; a working receiver answers with
        // a fix on the spot, and "No GPS fix" never fires.
        var (session, t) = try Self.walking()
        let stopAt = t
        var alarms = 0, probes = 0
        var tick = stopAt + 20
        while tick < stopAt + 13 * 60 {
            if session.needsFreshnessProbe(at: Date(timeIntervalSince1970: tick)) {
                probes += 1
                // the receiver's answer, where the walker is standing
                if let p = try Self.send(session, 600, 0, at: tick + 1, speed: 0), p.shouldAlertNoFix { alarms += 1 }
            }
            if let p = session.evaluate(at: Date(timeIntervalSince1970: tick)), p.shouldAlertNoFix { alarms += 1 }
            tick += 20
        }
        t = tick
        #expect(probes > 5)       // asked roughly once a minute
        #expect(alarms == 0)      // and never cried wolf
        #expect(session.progress?.offRouteState == .onRoute)
    }

    @Test func aReallyDeadReceiverStillRaisesTheAlarm() throws {
        // The probe must not become a way to silence the alarm. Nothing answers
        // it here, and no-fix still fires — once — after the timeout.
        let (session, t) = try Self.walking()
        var firedAt: Double?
        var tick = t + 20
        while tick < t + 300 {
            _ = session.needsFreshnessProbe(at: Date(timeIntervalSince1970: tick))  // asked, unanswered
            if let p = session.evaluate(at: Date(timeIntervalSince1970: tick)), p.shouldAlertNoFix, firedAt == nil {
                firedAt = tick - t
            }
            tick += 20
        }
        let at = try #require(firedAt)
        #expect(at >= OffRouteMonitor.Configuration().noFixAfter)
        #expect(session.progress?.offRouteState == .noFix)
    }

    @Test func probingIsOnlyAskedAfterSilence() throws {
        let (session, t) = try Self.walking()
        let last = t - 15 / 1.3
        #expect(!session.needsFreshnessProbe(at: Date(timeIntervalSince1970: last + 10)))
        #expect(session.needsFreshnessProbe(at: Date(timeIntervalSince1970: last + RecordingSession.probeAfterSilence)))
        try session.pause()
        #expect(!session.needsFreshnessProbe(at: Date(timeIntervalSince1970: last + 600)))
    }

    // MARK: - Far away is not "no signal"

    @Test func aGoodFixFarFromTheRouteIsDistantAndNeverNoFix() throws {
        // Walking to the trailhead from 2.5 km away with a 5 m fix: the screen
        // should say "not on this route" and how far — never "No GPS fix".
        let pkg = try Self.package()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("far-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = try RecordingSession.start(
            package: pkg, index: RouteIndex(segments: pkg.plannedRoute.segments), in: root,
            nativeConfig: RecordingSessionTests.nativeConfig, startedAt: Date(timeIntervalSince1970: 0))
        var t = 0.0, north = 2_500.0, sawNoFix = false
        var last: RecordingSession.Progress?
        while north > 2_100 {
            last = try Self.send(session, 500, north, at: t)
            sawNoFix = sawNoFix || last?.offRouteState == .noFix || last?.shouldAlertNoFix == true
            north -= 15; t += 15 / 1.3
        }
        let p = try #require(last)
        #expect(p.confidence == .distant)
        #expect(!sawNoFix)
        #expect(p.offsetM > 2_000 && p.offsetM.isFinite)   // the readout has a real number
        #expect(p.routeDistanceM == 0)                      // and nothing was credited
    }

    // MARK: - One weak fix does not lose the walker

    @Test func aWeakFixKeepsTheLastGoodPosition() throws {
        let (session, t) = try Self.walking()
        let before = try #require(session.progress)
        // One 70 m reading under trees, a few metres from the line.
        let p = try #require(try Self.send(session, 615, 10, at: t, hAcc: 70))
        #expect(p.confidence != .lost)                 // no red "Not on this route"
        #expect(p.routeDistanceM == before.routeDistanceM)
        #expect(p.remainingM == before.remainingM)     // Left does not blank
        #expect(p.fixLat == before.fixLat)             // the marker does not leap 70 m
        #expect(p.offRouteState == .degraded)          // the truth: weak signal
        #expect(p.rejectedFixCount == before.rejectedFixCount + 1)
    }
}
