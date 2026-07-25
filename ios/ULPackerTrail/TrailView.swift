import SwiftUI
import TripCore

/// The screen used while walking.
///
/// Text-first and large on purpose: this gets read in rain, in gloves, at the
/// end of a long day. The map arrives in a later milestone — everything shown
/// here is computed offline from the trip package, so it works with no signal.
struct TrailView: View {
    let package: TripPackage
    @State private var recorder: TrailRecorder
    @State private var recovery: ActivityJournal?
    /// Set only by the debug launch hook; see `ULPackerTrailApp`.
    private let autoStart: Bool

    init(package: TripPackage, autoStart: Bool = false) {
        self.package = package
        self.autoStart = autoStart
        _recorder = State(initialValue: TrailRecorder(package: package))
    }

    var body: some View {
        List {
            if let progress = recorder.progress {
                Section("Position") {
                    LabeledContent("Along route", value: km(progress.routeDistanceM))
                    LabeledContent("Remaining", value: km(progress.remainingM))
                    LabeledContent("Off the line", value: offsetText(progress))
                    LabeledContent("Signal", value: signalText(progress))
                }

                if let next = progress.nextCheckpoint, let distance = progress.distanceToNextCheckpointM {
                    Section("Next") {
                        LabeledContent(next.name.isEmpty ? next.kind : next.name, value: km(distance))
                        if let ele = next.ele { LabeledContent("Elevation", value: "\(ele) m") }
                    }
                }

                Section("Recording") {
                    LabeledContent("Fixes", value: "\(progress.fixCount)")
                    if progress.rejectedFixCount > 0 {
                        // Shown rather than hidden: a high reject count is the
                        // explanation for a track that looks worse than the walk.
                        LabeledContent("Rejected", value: "\(progress.rejectedFixCount)")
                    }
                }
            }

            Section {
                controls
            } footer: {
                Text(footerText).font(.footnote)
            }
        }
        .navigationTitle(package.trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) { statusBanner }
        .onAppear {
            recovery = recorder.pendingRecovery()
            if autoStart, recovery == nil { recorder.start() }
        }
        .alert("Off route", isPresented: offRouteBinding) {
            Button("OK") { recorder.clearOffRouteAlert() }
        } message: {
            Text("You seem to have left the planned route.")
        }
        .alert("Continue the interrupted walk?", isPresented: recoveryBinding) {
            Button("Continue") {
                if let recovery { recorder.resumeCrashedSession(recovery) }
                recovery = nil
            }
            Button("Discard", role: .destructive) {
                try? recovery?.delete()
                recovery = nil
            }
        } message: {
            Text("A recording was left unfinished. Everything already saved is intact.")
        }
    }

    // MARK: - Pieces

    @ViewBuilder private var statusBanner: some View {
        if let progress = recorder.progress, progress.offRouteState != .onRoute {
            // Never silent about GPS: "no fix" must not look like "on route".
            Text(bannerText(progress.offRouteState))
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(bannerColour(progress.offRouteState))
        }
    }

    @ViewBuilder private var controls: some View {
        switch recorder.status {
        case .idle, .needsPermission:
            Button("Start trail") { recorder.start() }
        case .recording:
            Button("Pause") { recorder.pause() }
            Button("Finish") { recorder.finish() }
        case .paused:
            Button("Resume") { recorder.resume() }
            Button("Finish") { recorder.finish() }
        case .finished(let activity):
            LabeledContent("Recorded", value: km(Double(activity.stats.distanceM)))
            LabeledContent("Duration", value: duration(activity.stats.durationS))
            LabeledContent("Fixes", value: "\(activity.stats.fixCount)")
            if activity.diagnostics.maxGapS > 60 {
                LabeledContent("Longest gap", value: "\(activity.diagnostics.maxGapS) s")
            }
            Button("Start another") { recorder.discard() }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Reset") { recorder.discard() }
        }
    }

    private var footerText: String {
        switch recorder.authorization {
        case .notDetermined: "Location permission has not been granted yet."
        case .denied: "Location is denied. Enable it in Settings to record."
        case .whenInUse, .always:
            "Recording continues with the screen off. iOS shows a blue indicator while it does."
        }
    }

    // MARK: - Formatting

    private func km(_ metres: Double) -> String {
        String(format: "%.2f km", metres / 1000)
    }

    private func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }

    private func offsetText(_ progress: RecordingSession.Progress) -> String {
        progress.offsetM.isFinite ? String(format: "%.0f m", progress.offsetM) : "—"
    }

    private func signalText(_ progress: RecordingSession.Progress) -> String {
        switch progress.confidence {
        case .tracking: "Good"
        case .ambiguous: "Ambiguous — route passes near itself"
        case .jumped: "Position jumped"
        case .lost: "No usable fix"
        }
    }

    private func bannerText(_ state: OffRouteMonitor.State) -> String {
        switch state {
        case .acquiring: "Acquiring position…"
        case .onRoute: ""
        case .suspect: "Possibly off route"
        case .offRoute: "Off route"
        case .degraded: "Weak GPS signal"
        case .noFix: "No GPS fix"
        }
    }

    private func bannerColour(_ state: OffRouteMonitor.State) -> Color {
        switch state {
        case .offRoute: .red.opacity(0.25)
        case .suspect, .degraded, .noFix: .orange.opacity(0.25)
        default: .clear
        }
    }

    private var offRouteBinding: Binding<Bool> {
        Binding(get: { recorder.pendingOffRouteAlert }, set: { if !$0 { recorder.clearOffRouteAlert() } })
    }

    private var recoveryBinding: Binding<Bool> {
        Binding(get: { recovery != nil }, set: { if !$0 { recovery = nil } })
    }
}
