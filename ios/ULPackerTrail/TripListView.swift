import SwiftUI
import TripCore

/// The trips on this phone, and the way to add one.
struct TripListView: View {
    let library: TripLibrary
    @Environment(ActiveSessionCoordinator.self) private var coordinator
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
                List {
                    // First, and in its own colour: the walk that is still
                    // going on, recording, paused or left unfinished. It was
                    // otherwise a row like any other trip, and after a "Not
                    // now" not even that.
                    if let walk = InProgressWalk.current(coordinator) {
                        Section("In progress") { InProgressRow(walk: walk) }
                    }
                    Section {
                        ForEach(packages, id: \.tripId) { package in
                            NavigationLink {
                                TripDetailView(package: package)
                            } label: {
                                TripRow(package: package)
                            }
                        }
                    } header: {
                        if InProgressWalk.current(coordinator) != nil { Text("Trips") }
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
    @Environment(ActiveSessionCoordinator.self) private var coordinator
    @State private var showing3D = false

    private var footer3D: String {
        switch coordinator.recorder?.status {
        case .recording: "Available when the walk is paused or finished."
        case .paused: "Uses Apple Maps online and some battery. Your walk stays paused."
        default: "Uses Apple Maps online. Nothing is downloaded until you open it."
        }
    }

    var body: some View {
        List {
            // First, above everything: a walk left unfinished on this trip has
            // nowhere else to be found once its prompt was answered "Not now".
            if let journal = coordinator.unfinishedWalk(for: package) {
                UnfinishedWalk(journal: journal, package: package)
            }

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

            // Looking at the route in 3D streams from Apple's servers, so it is
            // closed while a walk is recording, and nothing loads until it is
            // opened. A paused walk has its GPS off, and an evening at camp
            // looking at tomorrow is exactly when it is wanted: opening it is a
            // choice the walker makes, not something that happens to them.
            Section {
                Button { showing3D = true } label: {
                    Label("3D overview", systemImage: "mountain.2")
                }
                .disabled(coordinator.recorder?.status == .recording)
            } footer: {
                Text(footer3D)
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
        .fullScreenCover(isPresented: $showing3D) { Overview3DView.preview(of: package) }
        #if DEBUG
        // Screenshot runs cannot tap: open the 3D view directly.
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-uiTestOpen3D") { showing3D = true } }
        #endif
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

/// A walk on this trip that was left unfinished — the app ended while it was
/// paused or recording — with the two things that can be done about it.
struct UnfinishedWalk: View {
    let journal: ActivityJournal
    let package: TripPackage
    @Environment(ActiveSessionCoordinator.self) private var coordinator
    @State private var confirmingDiscard = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("Unfinished walk", systemImage: "pause.circle.fill")
                    .font(.headline)
                    .foregroundStyle(Color.brand)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Button {
                coordinator.continueRecovery(journal, package: package)
            } label: {
                Label("Continue walk", systemImage: "play.fill")
            }
            Button(role: .destructive) { confirmingDiscard = true } label: {
                Label("Discard walk", systemImage: "trash")
            }
            .confirmationDialog("Discard the unfinished walk?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard walk", role: .destructive) { coordinator.discardRecovery(journal) }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("Everything recorded on it is deleted. This cannot be undone.")
            }
        }
    }

    private var summary: String {
        let started = journal.session.startedAt.formatted(date: .abbreviated, time: .shortened)
        guard let walked = (try? journal.readCursor())??.walkedM else { return "Started \(started)" }
        return "Started \(started) · " + String(format: "%.1f km walked", walked / 1000)
    }

    /// Said on another trip's screen, where a new walk must not start beside it.
    static func elsewhereText(_ recovery: ActiveSessionCoordinator.Recovery) -> String {
        switch recovery {
        case .resumable(_, let other):
            "A walk on \(other.trip.name) is unfinished. Continue or discard it from that trip first."
        case .orphaned:
            "An unfinished walk belongs to a trip that is no longer on this phone. Import that trip to continue it, or discard it."
        }
    }
}

/// The one walk that is still going on, in whatever state it was left.
enum InProgressWalk {
    case live(TrailRecorder)
    case unfinished(ActivityJournal, TripPackage)
    case orphaned(ActivityJournal)

    @MainActor
    static func current(_ coordinator: ActiveSessionCoordinator) -> InProgressWalk? {
        if let recorder = coordinator.recorder, recorder.isActive { return .live(recorder) }
        switch coordinator.unfinished {
        case .resumable(let journal, let package): return .unfinished(journal, package)
        case .orphaned(let journal): return .orphaned(journal)
        case nil: return nil
        }
    }
}

private struct InProgressRow: View {
    let walk: InProgressWalk
    @Environment(ActiveSessionCoordinator.self) private var coordinator
    @State private var confirmingDiscard: ActivityJournal?

    var body: some View {
        Group {
            switch walk {
            case .live(let recorder):
                NavigationLink { TrailMapScreen(package: recorder.package) } label: {
                    row(recorder.package.trip.name,
                        symbol: recorder.status == .recording ? "figure.hiking" : "pause.fill",
                        state: recorder.status == .recording ? "Recording" : "Paused",
                        walked: recorder.walkedSoFarM, started: recorder.startedAt)
                }
            case .unfinished(let journal, let package):
                // Opens the walking screen, where Continue and Discard wait.
                NavigationLink { TrailMapScreen(package: package) } label: {
                    row(package.trip.name, symbol: "pause.fill", state: "Unfinished",
                        walked: (try? journal.readCursor())??.walkedM, started: journal.session.startedAt)
                }
            case .orphaned(let journal):
                HStack {
                    row("Unfinished walk", symbol: "questionmark", state: "Its trip is no longer on this phone",
                        walked: (try? journal.readCursor())??.walkedM, started: journal.session.startedAt)
                    Button("Discard", role: .destructive) { confirmingDiscard = journal }
                        .buttonStyle(.borderless)
                }
            }
        }
        .listRowBackground(Color.inProgress.opacity(0.13))
        .confirmationDialog(
            "Discard the unfinished walk?",
            isPresented: Binding(get: { confirmingDiscard != nil }, set: { if !$0 { confirmingDiscard = nil } }),
            titleVisibility: .visible,
            presenting: confirmingDiscard
        ) { journal in
            Button("Discard walk", role: .destructive) { coordinator.discardRecovery(journal) }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("Everything recorded on it is deleted. This cannot be undone.")
        }
    }

    private func row(_ title: String, symbol: String, state: String, walked: Double?, started: Date?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.inProgress, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(1)
                Text(detail(state: state, walked: walked, started: started))
                    .font(.subheadline)
                    .foregroundStyle(Color.inProgress)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func detail(state: String, walked: Double?, started: Date?) -> String {
        var parts = [state]
        if let walked { parts.append(String(format: "%.1f km", walked / 1000)) }
        // Day, month and time, no year: it is this week's walk, and the long
        // form pushed the line onto a second row.
        if let started { parts.append("since " + started.formatted(.dateTime.day().month(.abbreviated).hour().minute())) }
        return parts.joined(separator: " · ")
    }
}
