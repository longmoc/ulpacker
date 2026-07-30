import SwiftUI
import TripCore

/// The trips on this phone, and the way to add one.
struct TripListView: View {
    let library: TripLibrary
    @State private var choosingFile = false

    var body: some View {
        Group {
            switch library.state {
            case .loading:
                ProgressView()
            case .failed(let message):
                // An empty phone is the normal first run, not a failure. The
                // wording used to report that no trip was bundled with the
                // build, which was true and useless: nothing the person
                // holding it could act on.
                ContentUnavailableView {
                    Label("No trips yet", systemImage: "map")
                } description: {
                    Text(message)
                } actions: {
                    Button("Add a trip") { choosingFile = true }
                }
            case .loaded(let packages):
                List(packages, id: \.tripId) { package in
                    NavigationLink {
                        TripDetailView(package: package)
                    } label: {
                        TripRow(package: package)
                    }
                }
            }
        }
        .navigationTitle("Trips")
        .toolbar {
            Button { choosingFile = true } label: {
                Label("Add trip", systemImage: "plus")
            }
        }
        // Two ways in, because a trip arrives two ways: opened into the app
        // from Files or AirDrop, or fetched from here. Neither covers the
        // other — a file someone sends lands in Files with nothing to open it,
        // and a file already on the phone needs asking for.
        .fileImporter(
            isPresented: $choosingFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { library.receive(url) }
            case .failure(let error):
                library.lastImport = .failed(error.localizedDescription)
            }
        }
        .alert(item: importAlert) { outcome in
            switch outcome {
            case .added(let name):
                Alert(
                    title: Text("Trip added"),
                    message: Text(name),
                    dismissButton: .default(Text("OK"))
                )
            case .failed(let message):
                Alert(
                    title: Text("Could not add that trip"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var importAlert: Binding<TripLibrary.ImportResult?> {
        Binding(get: { library.lastImport }, set: { library.lastImport = $0 })
    }
}

private struct TripRow: View {
    let package: TripPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(package.trip.name).font(.headline)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // Built as a plain String: interpolating into `Text` directly would resolve
    // to LocalizedStringKey, which cannot be concatenated.
    private var summary: String {
        [
            String(format: "%.1f km", package.distanceKM),
            "\(package.itinerary.count) days",
            "\(package.checkpoints.count) checkpoints"
        ].joined(separator: " · ")
    }
}

struct TripDetailView: View {
    let package: TripPackage
    @State private var store = ActivityStore()

    var body: some View {
        List {
            Section("Route") {
                LabeledContent("Distance", value: String(format: "%.1f km", package.distanceKM))
                if let ascent = package.plannedRoute.stats.ascentM {
                    LabeledContent("Ascent", value: "\(ascent) m")
                }
                if let descent = package.plannedRoute.stats.descentM {
                    LabeledContent("Descent", value: "\(descent) m")
                }
                LabeledContent("Points", value: "\(package.plannedRoute.stats.pointCount)")
                LabeledContent("Segments", value: "\(package.plannedRoute.stats.segmentCount)")
            }

            Section {
                NavigationLink {
                    TrailMapScreen(package: package)
                } label: {
                    Label("Start trail", systemImage: "figure.hiking")
                }
                NavigationLink {
                    ActivityListView(package: package)
                } label: {
                    LabeledContent {
                        Text("\(store.activities(for: package).count)")
                    } label: {
                        Label("Recorded walks", systemImage: "clock.arrow.circlepath")
                    }
                }
            }

            if let report = store.batteryRate(for: package) {
                BatteryForecastView(package: package, report: report)
            }

            Section("Itinerary") {
                ForEach(Array(Itinerary.combined(package).enumerated()), id: \.offset) { _, entry in
                    ItineraryRow(entry: entry)
                }
            }

            Section("Overnight stops") {
                ForEach(package.overnightCheckpoints, id: \.id) { checkpoint in
                    LabeledContent(
                        checkpoint.name,
                        value: String(format: "%.1f km", Double(checkpoint.routeDistanceM) / 1000)
                    )
                }
            }

            // Shown because it is the thing M1 is really testing: this number
            // was produced independently by the JS planner and recomputed here.
            Section("Package") {
                LabeledContent("Revision", value: "\(package.revision)")
                LabeledContent("Content hash", value: package.contentHash)
                    .font(.caption.monospaced())
            }
        }
        .navigationTitle(package.trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.reload() }
    }

}

/// One itinerary day, walking or not.
///
/// Off-route days are shown but visually set apart: they carry no geometry, so
/// there is nothing to navigate and nothing to follow. On those the walker
/// simply pauses the recording, which is why they need no controls here — only
/// to be present, in the right place, with the right number.
private struct ItineraryRow: View {
    let entry: Itinerary.Entry
    @State private var expanded = ProcessInfo.processInfo.arguments.contains("-uiTestExpandNotes")

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(entry.number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(entry.isWalking ? Color.white : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(entry.isWalking ? Color.brand : Color.secondary.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(entry.isWalking ? .primary : .secondary)

                if let summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }

                if let note {
                    // Planning notes run to several paragraphs. In a list they
                    // are context, not the content — one day's note should not
                    // push the rest of the trip off the screen — so collapsed
                    // shows the first block and a tap opens the rest.
                    MarkdownNote(
                        text: note,
                        font: .caption,
                        blockLimit: expanded ? nil : 1
                    )
                    .foregroundStyle(Color.subtle)
                    .lineLimit(expanded ? nil : 2)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } }
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var summary: String? {
        switch entry {
        case .walking(let day, _):
            var parts = [String(format: "%.1f km", Double(day.distanceM) / 1000)]
            if let ascent = day.ascentM { parts.append("↑\(ascent) m") }
            if let descent = day.descentM { parts.append("↓\(descent) m") }
            return parts.joined(separator: " · ")
        case .offRoute:
            return "Off route — pause recording"
        }
    }

    /// Notes are authored as Markdown in the planner, so rendering them raw
    /// would show literal `**` in the middle of a sentence. Inline-only
    /// interpretation keeps the line breaks the author wrote, which matters
    /// for a note that is really a checklist.
    /// The raw Markdown. Interpreting it is `MarkdownNote`'s job now — doing it
    /// here produced one flat run with `##` and `---` left in as characters.
    private var note: String? {
        let raw: String = switch entry {
        case .walking(let day, _): day.note
        case .offRoute(let day, _): day.note
        }
        return raw.isEmpty ? nil : raw
    }
}
