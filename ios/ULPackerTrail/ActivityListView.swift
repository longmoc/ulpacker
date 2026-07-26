import SwiftUI
import TripCore

/// The walks recorded for one trip.
struct ActivityListView: View {
    let package: TripPackage
    @State private var store = ActivityStore()

    var body: some View {
        List {
            if store.activities(for: package).isEmpty {
                ContentUnavailableView {
                    Label("No walks recorded yet", systemImage: "figure.hiking")
                } description: {
                    Text("Finish a trail and it is kept here.")
                }
            }
            ForEach(store.activities(for: package), id: \.activityId) { activity in
                ActivityRow(activity: activity)
            }
            .onDelete { offsets in
                for index in offsets { store.delete(store.activities(for: package)[index]) }
            }
        }
        .navigationTitle("Recorded walks")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.reload() }
    }
}

private struct ActivityRow: View {
    let activity: ActivityPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(activity.startedAt, format: .dateTime.day().month().year())
                    .font(.headline)
                Spacer()
                Text(String(format: "%.1f km", Double(activity.stats.distanceM) / 1000))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
            }

            Text(detail)
                .font(.caption)
                .foregroundStyle(Color.subtle)

            // Shown only when it survived its own reliability test — see
            // Power.Report.isReliable for why a short walk says nothing.
            if let power = activity.power, power.isReliable, let rate = power.percentPerHour {
                Label(batteryLine(power, rate: rate), systemImage: "battery.50")
                    .font(.caption)
                    .foregroundStyle(Color.subtle)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [duration, "\(activity.stats.fixCount) fixes"]
        if activity.diagnostics.recoveredFromCrash { parts.append("recovered") }
        if activity.diagnostics.maxGapS > 300 {
            parts.append("longest gap \(activity.diagnostics.maxGapS / 60) min")
        }
        return parts.joined(separator: " · ")
    }

    private var duration: String {
        let minutes = activity.stats.durationS / 60
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// The pocket figure is the one that matters for a multi-day walk, so it is
    /// named separately when it exists rather than hidden inside an average
    /// that includes time spent reading the map.
    private func batteryLine(_ power: Power.Report, rate: Double) -> String {
        var line = String(format: "%.1f%%/h", rate)
        if let background = power.backgroundPercentPerHour, power.backgroundS >= Power.minimumReliableS {
            line += String(format: " · %.1f%%/h in pocket", background)
        }
        if power.maxThermal != "nominal" { line += " · ran \(power.maxThermal)" }
        if power.lowPowerModeSeen { line += " · low power mode" }
        return line
    }
}

/// What recording the rest of the trip will cost.
///
/// Only appears once this phone has measured itself on this trip. Quoting a
/// forecast from a number nobody measured would be the most confident-looking
/// and least trustworthy thing on the screen.
struct BatteryForecastView: View {
    let package: TripPackage
    let report: Power.Report

    private var forecast: BatteryForecast.Result {
        BatteryForecast.make(
            package: package,
            profile: RouteProfiles.profile(for: package),
            // The pocket rate when there is one: nine days of walking is nine
            // days of the phone being in a pocket, not held.
            percentPerHour: pocketRate
        )
    }

    private var pocketRate: Double {
        if let background = report.backgroundPercentPerHour, report.backgroundS >= Power.minimumReliableS {
            return background
        }
        return report.percentPerHour ?? 0
    }

    var body: some View {
        Section {
            ForEach(forecast.days, id: \.number) { day in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Day \(day.number)").font(.subheadline.weight(.medium))
                        Text(day.title).font(.caption).foregroundStyle(Color.subtle).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(String(format: "%.0f%%", day.percent))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(day.exceedsFullCharge ? .red : Color.primary)
                }
            }
        } header: {
            Text("Battery per day")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        var lines = [
            String(
                format: "At %.1f%%/h measured on this phone. Recording only — "
                    + "nothing here counts photographs, the map on screen, or the night.",
                pocketRate
            )
        ]
        if let worst = forecast.worstDay {
            lines.append(
                String(format: "Longest day: %@ at %.0f%%.", worst.title, worst.percent)
            )
        }
        lines.append(String(format: "%.1f full charges across the trip.", forecast.chargesNeeded))
        return lines.joined(separator: " ")
    }
}
