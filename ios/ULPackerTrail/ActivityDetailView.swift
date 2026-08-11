import SwiftUI
import TripCore

/// One recorded walk, and the way to get it off the phone.
///
/// The reason this screen exists is the export: until now a finished walk lived
/// only in the app's container, reachable by cable and Finder and no other way.
/// A `ShareLink` over a GPX file is the door out — AirDrop it, drop it in Files,
/// send it to whatever keeps a walker's trips.
struct ActivityDetailView: View {
    let package: TripPackage
    let activity: ActivityPackage
    /// The exported file, written once on appear. `ShareLink` shares a real file
    /// so the sheet offers a named `.gpx`, not a blob of text.
    @State private var gpxURL: URL?

    var body: some View {
        List {
            Section("Walk") {
                LabeledContent("Date", value: activity.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Walked", value: String(format: "%.1f km", Double(activity.stats.distanceM) / 1000))
                LabeledContent("Duration", value: duration)
                LabeledContent("Fixes", value: "\(activity.stats.fixCount)")
                if activity.diagnostics.rejectedFixCount > 0 {
                    LabeledContent("Poor fixes", value: "\(activity.diagnostics.rejectedFixCount)")
                }
                if activity.diagnostics.maxGapS >= 60 {
                    LabeledContent("Longest gap", value: "\(activity.diagnostics.maxGapS / 60) min")
                }
                if activity.diagnostics.recoveredFromCrash {
                    LabeledContent("Recovered", value: "after an interruption")
                }
            }

            if let power = activity.power, power.isReliable, let rate = power.percentPerHour {
                Section("Battery") {
                    LabeledContent("Drain", value: String(format: "%.1f%%/h", rate))
                    if power.backgroundReliable, let pocket = power.backgroundPercentPerHour {
                        LabeledContent("In pocket", value: String(format: "%.1f%%/h", pocket))
                    }
                    if power.maxThermal != "nominal" {
                        LabeledContent("Ran", value: power.maxThermal)
                    }
                }
            }

            Section {
                if let gpxURL {
                    ShareLink(item: gpxURL) {
                        Label("Export as GPX", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Preparing…", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("The track you actually walked, to save or share.")
            }
        }
        .navigationTitle("Walk")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if gpxURL == nil { gpxURL = writeGPX() } }
    }

    private var duration: String {
        let minutes = activity.stats.durationS / 60
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// Write the GPX to a temp file named for the trip and the day, so the share
    /// sheet and whatever receives it show something a person recognises rather
    /// than a UUID.
    private func writeGPX() -> URL? {
        let stamp = activity.startedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let title = "\(package.trip.name) \(stamp)"
        let gpx = ActivityGPX.export(activity, name: title)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.safeName(title) + ".gpx")
        do {
            try gpx.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    /// A filename a filesystem will accept: no slashes, colons, or other
    /// separators that would split the name or be rejected.
    private static func safeName(_ text: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return text.components(separatedBy: unsafe).joined(separator: "-")
    }
}
