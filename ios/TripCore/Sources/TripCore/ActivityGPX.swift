import Foundation

/// A recorded walk, written out as GPX so it can leave the phone — saved,
/// shared, dropped into whatever a walker keeps their trips in.
///
/// This is the track that *happened*, not the route that was planned: the raw
/// fixes in the order they arrived, with their timestamps and elevations. It is
/// deliberately faithful rather than tidied — a shared record of the day, not a
/// cleaned line — but it is split into segments at real gaps, so a consumer does
/// not draw a straight line across a lunch stop or a tunnel where the signal
/// dropped. The gap that splits a segment is the same one that stops those
/// stretches counting as walked distance, so the two tell the same story.
public enum ActivityGPX {
    /// GPX 1.1 for one activity. `name` titles the track — usually the trip name
    /// and the date, which the activity itself does not carry.
    public static func export(_ activity: ActivityPackage, name: String) -> String {
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(
            #"<gpx version="1.1" creator="ULPacker Trail" xmlns="http://www.topografix.com/GPX/1/1">"#
        )
        lines.append("  <metadata>")
        lines.append("    <name>\(escape(name))</name>")
        lines.append("    <time>\(ISO8601.string(from: activity.startedAt))</time>")
        lines.append("  </metadata>")
        lines.append("  <trk>")
        lines.append("    <name>\(escape(name))</name>")

        for segment in segments(of: activity.fixes) {
            lines.append("    <trkseg>")
            for fix in segment {
                lines.append(#"      <trkpt lat="\#(coord(fix.lat))" lon="\#(coord(fix.lng))">"#)
                if let alt = fix.alt {
                    lines.append("        <ele>\(elevation(alt))</ele>")
                }
                lines.append("        <time>\(ISO8601.string(from: fix.t))</time>")
                lines.append("      </trkpt>")
            }
            lines.append("    </trkseg>")
        }

        lines.append("  </trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Break the fixes wherever the gap between them is too long to be one
    /// continuous stretch of walking — the same threshold walked distance uses,
    /// so a paused or dropped-out interval is a segment boundary here too.
    static func segments(of fixes: [ActivityPackage.Fix]) -> [[ActivityPackage.Fix]] {
        var segments: [[ActivityPackage.Fix]] = []
        var current: [ActivityPackage.Fix] = []
        for fix in fixes {
            if let last = current.last,
               fix.t.timeIntervalSince(last.t) > WalkedDistance.maxStepGapS {
                segments.append(current)
                current = []
            }
            current.append(fix)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func coord(_ value: Double) -> String { String(format: "%.7f", value) }
    private static func elevation(_ value: Double) -> String { String(format: "%.1f", value) }

    /// The five characters that are not themselves in XML text.
    private static func escape(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }
}
