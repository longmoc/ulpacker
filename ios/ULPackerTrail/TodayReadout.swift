import SwiftUI
import TripCore

/// The numbers under the map while walking: how much of today is done, what
/// comes next, and whether there is daylight enough to get there.
///
/// Read in a glance, in sun, with a pack on — so large figures first, one line
/// for each question, and nothing that does not change a decision. How far off
/// the line the walker is only appears once it is far enough to matter.
struct TodayReadout: View {
    let guidance: DayPlanner.Guidance
    let walkedM: Double
    let offLineM: Double?

    /// Under this, GPS noise and the width of the path account for it.
    private static let offLineWorthShowingM = 25.0
    /// Less daylight than this at the far end is worth a second look.
    private static let tightDaylightS: TimeInterval = 3_600

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            today
            ProgressView(value: min(guidance.doneM ?? 0, guidance.totalM), total: max(guidance.totalM, 1))
                .tint(.brand)
            nextStop
            daylight
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var today: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(guidance.dayNumber.map { "Day \($0)" } ?? "Route")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(Self.km(guidance.doneM)) / \(Self.km(guidance.totalM))")
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            if guidance.arrived {
                Label("Arrived", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.brand)
            } else {
                Text(leftToday)
                    .font(.footnote.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private var leftToday: String {
        var parts: [String] = []
        if let ascent = guidance.ascentLeftM { parts.append("↑" + Self.climb(ascent)) }
        if let time = guidance.timeLeft { parts.append(Self.duration(time)) }
        return parts.isEmpty ? "" : parts.joined(separator: " · ") + " left"
    }

    private var nextStop: some View {
        HStack(spacing: 6) {
            Image(systemName: guidance.next.kind?.symbolName ?? "flag.checkered")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(guidance.next.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(0)
            Spacer(minLength: 4)
            Text(stopFigures)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    private var stopFigures: String {
        let stop = guidance.next
        // Across the ground it is a different number, and must read as one: 2 km
        // in a straight line over a ridge is not 2 km of walking.
        if stop.isStraightLine { return Self.distance(stop.distanceM) + " straight line" }
        var parts = [Self.distance(stop.distanceM)]
        if let ascent = stop.ascentM, ascent >= 5 { parts.append("↑" + Self.climb(ascent)) }
        if let arrival = stop.arrival { parts.append(Self.clock(arrival)) }
        return parts.joined(separator: " · ")
    }

    private var daylight: some View {
        HStack(spacing: 4) {
            if !guidance.arrived, let line = daylightLine {
                Text(line)
                    .foregroundStyle(daylightColour)
                    .fontWeight(daylightColour == .secondary ? .regular : .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 4)
            Text(rightOfDaylight)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.caption.monospacedDigit())
    }

    private var daylightLine: String? {
        guard let sunset = guidance.sunset else { return nil }
        guard let spare = guidance.spareDaylight else { return "Sunset " + Self.clock(sunset) }
        if spare < 0 { return "Sunset \(Self.clock(sunset)) · \(Self.duration(-spare)) after dark" }
        return "Sunset \(Self.clock(sunset)) · \(Self.duration(spare)) spare"
    }

    private var daylightColour: Color {
        guard let spare = guidance.spareDaylight else { return .secondary }
        if spare < 0 { return .red }
        return spare < Self.tightDaylightS ? .orange : .secondary
    }

    /// Distance actually walked, always knowable; distance off the line beside
    /// it once there is enough of it to explain the tether on the map.
    private var rightOfDaylight: String {
        if let offLineM, offLineM >= Self.offLineWorthShowingM {
            return Self.distance(offLineM) + " off line"
        }
        return "Walked " + Self.km(walkedM)
    }

    // MARK: - Formatting

    private static func km(_ metres: Double?) -> String {
        guard let metres, metres.isFinite else { return "—" }
        return String(format: "%.1f km", metres / 1000)
    }

    private static func distance(_ metres: Double) -> String {
        // Past a few kilometres the exact figure stops meaning anything.
        if metres >= 20_000 { return "far" }
        return metres >= 1_000 ? String(format: "%.1f km", metres / 1000) : "\(Int(metres.rounded())) m"
    }

    /// To the nearest ten metres: anything finer is noise in the elevation data,
    /// and would disagree by a metre or two with the same stop in the panel.
    private static func climb(_ metres: Double) -> String {
        "\(Int((metres / 10).rounded()) * 10) m"
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
    }

    private static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
