import Foundation
import Testing
@testable import TripCore

/// Exporting a recorded walk as GPX — the track leaving the phone.
@MainActor
struct ActivityGPXTests {
    static func fix(_ seq: Int, _ lat: Double, _ lng: Double, at seconds: Double, alt: Double? = 1500) -> ActivityPackage.Fix {
        .init(seq: seq, t: Date(timeIntervalSince1970: seconds), lat: lat, lng: lng, hAcc: 8, alt: alt)
    }

    // MARK: - Segmenting at gaps

    @Test func aLongGapStartsANewSegment() {
        let fixes = [
            Self.fix(1, 45.90, 6.80, at: 0),
            Self.fix(2, 45.91, 6.80, at: 60),
            // A twenty-minute break: the next stretch is a separate segment.
            Self.fix(3, 45.92, 6.80, at: 1_260),
            Self.fix(4, 45.93, 6.80, at: 1_320)
        ]
        let segments = ActivityGPX.segments(of: fixes)
        #expect(segments.count == 2)
        #expect(segments[0].map(\.seq) == [1, 2])
        #expect(segments[1].map(\.seq) == [3, 4])
    }

    @Test func aContinuousWalkIsOneSegment() {
        let fixes = (0..<5).map { Self.fix($0 + 1, 45.9 + Double($0) * 0.001, 6.8, at: Double($0) * 30) }
        #expect(ActivityGPX.segments(of: fixes).count == 1)
    }

    // MARK: - The document

    func activity(fixes: [ActivityPackage.Fix]) -> ActivityPackage {
        ActivityPackage(
            format: ActivityPackage.expectedFormat,
            schemaVersion: ActivityPackage.supportedSchemaVersion,
            activityId: "act-1", tripId: "trip-1", tripRevision: 1, stageId: nil,
            status: .finished,
            startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 120),
            nativeConfig: RecordingSessionTests.nativeConfig,
            fixes: fixes,
            stats: .init(fixCount: fixes.count, usableFixCount: fixes.count, distanceM: 100, durationS: 120),
            diagnostics: .init(maxGapS: 0, maxGapM: 0, rejectedFixCount: 0, recoveredFromCrash: false),
            power: nil
        )
    }

    @Test func writesAPointPerFixWithTimeAndElevation() {
        let fixes = [
            Self.fix(1, 45.900_123_4, 6.800_5, at: 0, alt: 1500.4),
            Self.fix(2, 45.901, 6.801, at: 30, alt: 1512.0),
            Self.fix(3, 45.902, 6.802, at: 60, alt: nil)   // no altitude → no <ele>
        ]
        let gpx = ActivityGPX.export(activity(fixes: fixes), name: "TMB day 1")

        #expect(gpx.hasPrefix("<?xml"))
        #expect(gpx.contains(#"<gpx version="1.1""#))
        #expect(gpx.contains("<trk>"))
        // One trackpoint per fix.
        #expect(gpx.components(separatedBy: "<trkpt ").count - 1 == 3)
        // Coordinates at seven decimals, elevation where the fix had it.
        #expect(gpx.contains(#"lat="45.9001234" lon="6.8005000""#))
        #expect(gpx.contains("<ele>1500.4</ele>"))
        // The fix with no altitude emits no elevation element for itself; two
        // of the three had one.
        #expect(gpx.components(separatedBy: "<ele>").count - 1 == 2)
        // A real timestamp, not a placeholder.
        #expect(gpx.contains("<time>1970-01-01T00:00:00.000Z</time>"))
    }

    @Test func aGapSplitsTheTrackIntoTwoSegments() {
        let fixes = [
            Self.fix(1, 45.90, 6.80, at: 0),
            Self.fix(2, 45.91, 6.80, at: 60),
            Self.fix(3, 45.92, 6.80, at: 1_260)
        ]
        let gpx = ActivityGPX.export(activity(fixes: fixes), name: "x")
        #expect(gpx.components(separatedBy: "<trkseg>").count - 1 == 2)
    }

    @Test func theNameIsXmlEscaped() {
        let gpx = ActivityGPX.export(activity(fixes: [Self.fix(1, 45.9, 6.8, at: 0)]), name: "Ben & Jerry's <trip>")
        #expect(gpx.contains("Ben &amp; Jerry&apos;s &lt;trip&gt;"))
        #expect(!gpx.contains("Ben & Jerry's <trip>"))
    }
}
