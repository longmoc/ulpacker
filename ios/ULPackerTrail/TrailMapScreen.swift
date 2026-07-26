import CoreLocation
import SwiftUI
import TripCore

/// The screen used while actually walking: map on top, the numbers that matter
/// underneath, controls at the bottom where a thumb reaches.
///
/// Layout choices are for use in the field rather than for a screenshot. The
/// map gets the space because "where am I relative to the line" is the question
/// being asked; the readouts are large because they get read in rain, in
/// gloves, at the end of a long day; and the status band never goes quiet,
/// because "no GPS fix" must never look like "on route".
struct TrailMapScreen: View {
    let package: TripPackage
    @State private var recorder: TrailRecorder
    @State private var recovery: ActivityJournal?
    @State private var followsPosition = true
    private let autoStart: Bool

    init(package: TripPackage, autoStart: Bool = false) {
        self.package = package
        self.autoStart = autoStart
        _recorder = State(initialValue: TrailRecorder(package: package))
    }

    var body: some View {
        VStack(spacing: 0) {
            mapSection
            readouts
            controls
        }
        .navigationTitle(package.trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            recovery = recorder.pendingRecovery()
            if autoStart, recovery == nil { recorder.start() }
            #if DEBUG
            applyScriptedAction()
            #endif
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

    // MARK: - Map

    private var mapSection: some View {
        ZStack(alignment: .topTrailing) {
            RouteMapView(
                package: package,
                position: currentCoordinate,
                routeDistanceM: recorder.progress?.routeDistanceM,
                followsPosition: followsPosition
            )
            .ignoresSafeArea(edges: .horizontal)

            VStack(spacing: 8) {
                // Re-centring is a manual affordance on purpose: the map should
                // not fight someone who panned away to look at what is ahead.
                Button {
                    followsPosition.toggle()
                } label: {
                    Image(systemName: followsPosition ? "location.fill" : "location")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel(followsPosition ? "Stop following position" : "Follow position")
            }
            .padding(12)

            if let banner = statusBanner {
                Text(banner.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(banner.colour)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Readouts

    private var readouts: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                readout("Done", km(recorder.progress?.routeDistanceM))
                Divider().frame(height: 44)
                readout("Left", km(recorder.progress?.remainingM))
                Divider().frame(height: 44)
                readout("Off line", metres(recorder.progress?.offsetM))
            }
            .padding(.vertical, 12)

            if let here = recorder.progress?.routeDistanceM {
                Divider()
                upcoming(from: here)
            }
        }
        .background(.background)
    }

    /// The next few stops, not just the next one.
    ///
    /// "Water in 2 km" answers one question. Deciding whether to push on to the
    /// refuge or stop at the bivouac needs to see several stops and the gaps
    /// between them at once — which is the judgement actually being made late
    /// in the day, and the reason the trip carries 56 checkpoints.
    private func upcoming(from here: Double) -> some View {
        VStack(spacing: 0) {
            ForEach(package.upcomingCheckpoints(after: here), id: \.id) { checkpoint in
                let distance = Double(checkpoint.routeDistanceM) - here
                HStack(spacing: 10) {
                    Image(systemName: checkpoint.checkpointKind.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(tint(for: checkpoint.checkpointKind)))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(checkpoint.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if let ele = checkpoint.ele {
                            Text("\(ele) m").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(km(distance))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        if let eta = estimatedTime(to: distance) {
                            Text(eta).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                Divider().padding(.leading, 52)
            }
        }
    }

    private func tint(for kind: CheckpointKind) -> Color {
        switch kind {
        case .overnight, .refuge: .orange
        case .water: .teal
        case .food, .resupply: .green
        case .hazard: .red
        case .transport: .purple
        case .pass: .brown
        case .viewpoint: .blue
        case .poi: .gray
        }
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Controls

    private var controls: some View {
        Group {
            switch recorder.status {
            case .idle, .needsPermission:
                bigButton("Start trail", tint: .indigo) { recorder.start() }
            case .recording:
                HStack(spacing: 12) {
                    bigButton("Pause", tint: .secondary) { recorder.pause() }
                    bigButton("Finish", tint: .indigo) { recorder.finish() }
                }
            case .paused:
                HStack(spacing: 12) {
                    bigButton("Resume", tint: .indigo) { recorder.resume() }
                    bigButton("Finish", tint: .secondary) { recorder.finish() }
                }
            case .finished(let activity):
                VStack(spacing: 8) {
                    Text("\(km(Double(activity.stats.distanceM))) recorded · \(activity.stats.fixCount) fixes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    bigButton("Start another", tint: .indigo) { recorder.discard() }
                }
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                    bigButton("Reset", tint: .secondary) { recorder.discard() }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.background)
    }

    private func bigButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                // Deliberately tall: this gets pressed with cold hands.
                .frame(height: 50)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }

    // MARK: - Derived

    private var currentCoordinate: CLLocationCoordinate2D? {
        // The snapped position, not the raw fix: drawing the raw observation
        // puts the walker beside the line whenever GPS is noisy, which reads as
        // a bug rather than as noise. `Off line` already reports the real gap.
        guard let progress = recorder.progress, progress.confidence != .lost else { return nil }
        return CLLocationCoordinate2D(latitude: progress.lat, longitude: progress.lng)
    }

    private var statusBanner: (text: String, colour: Color)? {
        guard let state = recorder.progress?.offRouteState else { return nil }
        switch state {
        case .onRoute: return nil
        case .acquiring: return ("Acquiring position…", .gray)
        case .suspect: return ("Possibly off route", .orange)
        case .offRoute: return ("Off route", .red)
        case .degraded: return ("Weak GPS signal", .orange)
        case .noFix: return ("No GPS fix", .red)
        }
    }

    /// Naismith with a slope correction, computed from the planned route's own
    /// profile — no network, no service, works in a valley with no signal.
    private func estimatedTime(to distanceM: Double) -> String? {
        guard distanceM > 0 else { return nil }
        let hours = distanceM / 1000 / 4.0
        let minutes = Int((hours * 60).rounded())
        if minutes < 60 { return "~\(minutes) min" }
        return "~\(minutes / 60) h \(minutes % 60) min"
    }

    private func km(_ metres: Double?) -> String {
        guard let metres, metres.isFinite else { return "—" }
        return String(format: "%.2f", metres / 1000) + " km"
    }

    private func metres(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f m", value)
    }

    private var offRouteBinding: Binding<Bool> {
        Binding(get: { recorder.pendingOffRouteAlert }, set: { if !$0 { recorder.clearOffRouteAlert() } })
    }

    private var recoveryBinding: Binding<Bool> {
        Binding(get: { recovery != nil }, set: { if !$0 { recovery = nil } })
    }

    #if DEBUG
    /// Drives the screen into a state for automated screenshots.
    ///
    /// Reaching pause or finish otherwise needs a tap, and a headless simulator
    /// run has no accessibility permission to synthesise one. Compiled out of
    /// release builds; `-uiTestActionDelay` gives simulated fixes time to
    /// arrive first, so the captured state has real numbers in it rather than
    /// an empty recording.
    private func applyScriptedAction() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-uiTestAction"),
              index + 1 < arguments.count else { return }
        let action = arguments[index + 1]
        let delay = arguments.firstIndex(of: "-uiTestActionDelay")
            .flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 8

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            switch action {
            case "pause": recorder.pause()
            case "finish": recorder.finish()
            default: break
            }
        }
    }
    #endif
}
