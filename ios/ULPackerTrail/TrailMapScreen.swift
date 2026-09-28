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
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(ActiveSessionCoordinator.self) private var coordinator
    /// Resolved from the coordinator on appear, so the walk this screen drives
    /// is the app-owned one — the same object whether the screen is opened fresh,
    /// re-opened over a walk already running, or pushed to continue a recovery.
    @State private var recorder: TrailRecorder?
    /// Shown when the back button is pressed mid-walk: the recording keeps going
    /// in the background, and leaving is a decision worth making on purpose.
    @State private var confirmingLeave = false
    /// Whether a real basemap is available for this trip. Resolved once on
    /// appear — even the cheap pack check touches disk — so the screen can say
    /// the map is route-only rather than leave the blank canvas unexplained.
    @State private var basemapMissing = false
    @State private var followMode: RouteMapView.FollowMode = .northUp
    @State private var panelDetent: TrailInfoPanel.Detent = .collapsed
    @State private var panelTab: TrailInfoPanel.Tab = .profile
    @State private var kindFilter: Set<CheckpointKind> = []
    /// The walking day the screen is narrowed to, or nil for the whole trip.
    @State private var dayScope: Int?
    @State private var selectedCheckpoint: TripPackage.Checkpoint?
    /// The pin tapped on the map, and where it is on screen.
    @State private var callout: (checkpoint: TripPackage.Checkpoint, at: CGPoint)?
    private let autoStart: Bool

    init(package: TripPackage, autoStart: Bool = false) {
        self.package = package
        self.autoStart = autoStart
    }

    var body: some View {
        Group {
            if let recorder {
                content(recorder)
            } else {
                // The one frame before onAppear resolves the recorder. The map
                // is what takes time to draw anyway, so a plain wait here is
                // invisible in practice.
                Color(.systemBackground)
            }
        }
        .onAppear {
            if recorder == nil {
                let resolved = coordinator.recorder(for: package)
                recorder = resolved
                if autoStart, !resolved.isActive { resolved.start() }
            }
            basemapMissing = !RouteMapView.hasUsablePack(for: package)
            #if DEBUG
            applyScriptedAction()
            #endif
        }
    }

    private func content(_ recorder: TrailRecorder) -> some View {
        VStack(spacing: 0) {
            mapSection(recorder)
            readouts(recorder)
            controls(recorder)
        }
        .navigationTitle(package.trip.name)
        .navigationBarTitleDisplayMode(.inline)
        // While a walk is live the screen owns the back button, so leaving is a
        // deliberate choice rather than a reflex that looks like it stopped the
        // recording. It does not stop it — the app keeps recording — but the
        // walker should know that, not assume the opposite.
        .navigationBarBackButtonHidden(recorder.isActive)
        .toolbar {
            if recorder.isActive {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { confirmingLeave = true } label: {
                        Label("Back", systemImage: "chevron.backward")
                    }
                }
            }
        }
        .confirmationDialog(
            "Leave while recording?",
            isPresented: $confirmingLeave,
            titleVisibility: .visible
        ) {
            Button("Leave — keep recording") { dismiss() }
            Button("Stay", role: .cancel) {}
        } message: {
            Text("The walk keeps recording in the background. You can come back to it from the trip.")
        }
        // The recorder buffers fixes and flushes every ten of them or every
        // minute — proportional to walking, which is what the battery needs.
        // Leaving the foreground is the one moment that schedule is not enough:
        // iOS may never hand control back, and whatever is buffered is what a
        // kill would cost. Routed through the coordinator so it fires for the
        // app-owned walk regardless of which screen is showing.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                coordinator.flushForBackgrounding()
            }
        }
        .alert("Off route", isPresented: offRouteBinding(recorder)) {
            Button("OK") { recorder.clearOffRouteAlert() }
        } message: {
            Text("You seem to have left the planned route.")
        }
    }

    // MARK: - Map

    private func mapSection(_ recorder: TrailRecorder) -> some View {
        ZStack(alignment: .topTrailing) {
            RouteMapView(
                package: package,
                position: currentCoordinate(recorder),
                // No route distance while off the route, which is also what
                // turns the marker from a direction arrow into a plain dot:
                // the route cannot say which way the walker faces when it does
                // not know where they are on it.
                routeDistanceM: isOnRoute(recorder) ? recorder.progress?.routeDistanceM : nil,
                courseDegrees: recorder.progress?.courseDegrees,
                snappedTo: snappedCoordinate(recorder),
                focusRange: scopeRange,
                followMode: followMode,
                kindFilter: kindFilter,
                highlighted: callout?.checkpoint,
                onSelectCheckpoint: { checkpoint, point in
                    // Answer where the walker pointed. Sending them to a panel
                    // instead would make them look away from the very thing
                    // they just asked about.
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                        callout = (checkpoint, point)
                    }
                }
            )
            .ignoresSafeArea(edges: .horizontal)

            // Camera mode, cycled the way every map app does it: free →
            // centred → centred and turned the way you are walking. One button
            // rather than three, because it is pressed one-handed on the move.
            //
            // Bottom-trailing, above the attribution: the compass lives
            // top-right and this is where a thumb already is.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    followMode = switch followMode {
                    case .free: .northUp
                    case .northUp: .courseUp
                    case .courseUp: .free
                    }
                }
            } label: {
                Image(systemName: followModeIcon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(followMode == .free ? Color.primary : Color.brand)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            }
            .accessibilityLabel(followModeLabel)
            .padding(.trailing, 12)
            // Above both the collapsed panel handle and the attribution
            // button, which must stay tappable for the map licence.
            .padding(.bottom, 92)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            if let callout {
                CheckpointCallout(
                    checkpoint: callout.checkpoint,
                    anchor: callout.at,
                    from: recorder.progress?.routeDistanceM,
                    onOpenDetails: {
                        selectedCheckpoint = callout.checkpoint
                        panelTab = .stops
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                            panelDetent = .expanded
                            self.callout = nil
                        }
                    },
                    onDismiss: { withAnimation(.easeOut(duration: 0.18)) { self.callout = nil } }
                )
            }

            // Over the map, never over the readouts: the live numbers must
            // stay visible whatever the panel is doing.
            TrailInfoPanel(
                package: package,
                routeDistanceM: recorder.progress?.routeDistanceM,
                selected: $selectedCheckpoint,
                detent: $panelDetent,
                tab: $panelTab,
                dayScope: $dayScope,
                kindFilter: $kindFilter
            )
            .onChange(of: dayScope) { _, scope in
                // Reading a day is not following yourself. Leaving the camera
                // on the walker would drag the map off the day the moment the
                // next fix arrived; the walker takes following back by pressing
                // the button, which now shows the truth either way.
                if scope != nil { followMode = .free }
            }

            if basemapMissing {
                // The route still draws; the ground under it does not. Said
                // plainly so the blank canvas reads as "no map installed" rather
                // than "the map is broken". Bottom-leading, clear of the
                // centred status badge and the top-right compass.
                Label("Offline basemap unavailable", systemImage: "square.dashed")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.subtle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.leading, 12)
                    .padding(.bottom, 92)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if let banner = statusBanner(recorder) {
                // A badge, not a bar. Full width it spanned the map edge to
                // edge and swallowed the compass with it, so the moment the
                // walker most needs to know which way north is, the app hid it.
                // Sized to its text and inset clear of the compass instead.
                Text(banner.text)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(banner.colour, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
                    .padding(.top, 10)
                    // The compass sits top-right and is 44 pt of it; leaving
                    // that much on both sides keeps the badge centred and the
                    // compass uncovered.
                    .padding(.horizontal, 68)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Readouts

    private func readouts(_ recorder: TrailRecorder) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Distance walked, not progress along the line. They are
                // different numbers — cut a corner and the projection races
                // ahead of the legs — and this one is always knowable, on the
                // route or off it, so it is never withheld.
                readout("Walked", km(recorder.progress?.walkedM))
                Divider().frame(height: 44)
                readout("Left", km(isOnRoute(recorder) ? recorder.progress?.remainingM : nil))
                Divider().frame(height: 44)
                readout("Off line", metres(recorder.progress?.offsetM))
            }
            .padding(.vertical, 12)

        }
        .background(.background)
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

    /// Distance, and what it cost. The battery line only appears once the
    /// measurement is long enough to mean something — a first number that is
    /// wrong is the one that gets remembered.
    private func finishedSummary(_ activity: ActivityPackage) -> String {
        var line = "\(km(Double(activity.stats.distanceM))) saved · \(activity.stats.fixCount) fixes"
        if let power = activity.power, power.isReliable, let rate = power.percentPerHour {
            line += String(format: "\n%.1f%% battery per hour", rate)
        }
        return line
    }

    private func readout(_ label: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Controls

    private func controls(_ recorder: TrailRecorder) -> some View {
        VStack(spacing: 8) {
            // A save problem rides above the transport controls rather than
            // replacing them: the walk is still going, Pause and Finish still
            // work, and Retry is offered instead of a dead end. It used to
            // collapse the whole screen to a single Reset that deleted the walk.
            if let writeError = recorder.writeError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(writeError)
                        .font(.caption)
                        .foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { recorder.retrySave() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }

            switch recorder.status {
            case .idle, .needsPermission:
                if coordinator.isBlocked(for: package) {
                    // Another trip is recording. Starting a second walk would
                    // mean two sessions competing for one slot; say why instead.
                    Text("A walk is already recording on another trip. Finish it first.")
                        .font(.footnote)
                        .foregroundStyle(Color.subtle)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                } else {
                    bigButton("Start trail", tint: .brand) { recorder.start() }
                }
            case .recording:
                HStack(spacing: 12) {
                    bigButton("Pause", tint: .secondary) { recorder.pause() }
                    bigButton("Finish", tint: .brand) { recorder.finish() }
                }
            case .paused:
                HStack(spacing: 12) {
                    bigButton("Resume", tint: .brand) { recorder.resume() }
                    bigButton("Finish", tint: .secondary) { recorder.finish() }
                }
            case .finished(let activity):
                VStack(spacing: 8) {
                    Text(finishedSummary(activity))
                        .font(.subheadline)
                        .foregroundStyle(Color.subtle)
                        .multilineTextAlignment(.center)
                    bigButton("Done", tint: .brand) {
                        recorder.clearFinished()
                        coordinator.release(recorder)
                    }
                }
            case .failed(let message):
                // Only a start or resume that produced no session lands here —
                // there is nothing recording and nothing to lose. Dismiss
                // returns to idle; any journal on disk is left for another try.
                VStack(spacing: 8) {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                    bigButton("Dismiss", tint: .secondary) {
                        recorder.dismissFailure()
                        coordinator.release(recorder)
                    }
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

    private var followModeIcon: String {
        switch followMode {
        case .free: "location"
        case .northUp: "location.fill"
        case .courseUp: "location.north.line.fill"
        }
    }

    private var followModeLabel: String {
        switch followMode {
        case .free: "Follow my position"
        case .northUp: "Turn the map the way I am walking"
        case .courseUp: "Stop following my position"
        }
    }

    // MARK: - Derived

    /// Where the receiver says the walker is. Never the projection.
    private func currentCoordinate(_ recorder: TrailRecorder) -> CLLocationCoordinate2D? {
        guard let progress = recorder.progress else { return nil }
        return CLLocationCoordinate2D(latitude: progress.fixLat, longitude: progress.fixLng)
    }

    /// The matched point, drawn only when the gap is wide enough to explain.
    ///
    /// Below this the marker and the line are touching anyway and a tether
    /// would be a scribble; above it the walker deserves to see what the "off
    /// line" figure is measuring.
    private func snappedCoordinate(_ recorder: TrailRecorder) -> CLLocationCoordinate2D? {
        guard isOnRoute(recorder), let progress = recorder.progress, progress.offsetM > 25
        else { return nil }
        return CLLocationCoordinate2D(latitude: progress.lat, longitude: progress.lng)
    }

    /// The route distances covered by the chosen day.
    private var scopeRange: ClosedRange<Double>? {
        guard let dayScope, let day = package.itinerary.first(where: { $0.index == dayScope })
        else { return nil }
        return Double(day.startRouteM)...Double(day.endRouteM)
    }

    /// Whether the position on screen is a place on this route.
    ///
    /// Neither a poor fix (`.lost`, before any good position exists) nor a good
    /// fix far from the route (`.distant`) is. Once a good position exists, a
    /// poor fix no longer arrives here as `.lost` at all — the session carries
    /// the last good position through it — so the readouts hold steady under
    /// trees instead of blanking with every weak reading.
    private func isOnRoute(_ recorder: TrailRecorder) -> Bool {
        switch recorder.progress?.confidence {
        case .lost, .distant, nil: false
        default: true
        }
    }

    private func statusBanner(_ recorder: TrailRecorder) -> (text: String, colour: Color)? {
        if let offRouteText = offRouteText(recorder) { return (offRouteText, .red) }

        // The matcher knows when it might be wrong, and until now the app threw
        // that away and showed a confident number anyway. On a loop the first
        // and last kilometre are the same ground: standing at Les Houches, "you
        // are at metre zero" and "you have walked 164 km" fit the evidence
        // equally well. Saying so costs a line of text; not saying so means the
        // one moment the app is unsure is the one moment it looks certain.
        switch recorder.progress?.confidence {
        case .ambiguous: return ("Two places on the route match", .orange)
        case .jumped: return ("Position jumped", .orange)
        default: break
        }

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

    /// The state as the walker should read it. A match the route refused to
    /// make is not "possibly off route" — it is not this route at all.
    private func offRouteText(_ recorder: TrailRecorder) -> String? {
        // Only a good fix far from the route earns this. A weak signal is a
        // statement about the receiver, and says so through the GPS states
        // below ("Weak GPS signal", "No GPS fix"), never as red "Not on this
        // route" — which is what one 70 m fix under trees used to produce.
        guard recorder.progress?.confidence == .distant else { return nil }
        return "Not on this route"
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
        // Past a few kilometres the exact figure stops meaning anything — you
        // are not near this route at all, and "10,044,476 m" reads as a bug.
        if value >= 20_000 { return "far off" }
        if value >= 1_000 { return String(format: "%.1f km", value / 1000) }
        return String(format: "%.0f m", value)
    }

    private func offRouteBinding(_ recorder: TrailRecorder) -> Binding<Bool> {
        Binding(get: { recorder.pendingOffRouteAlert }, set: { if !$0 { recorder.clearOffRouteAlert() } })
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
            case "pause": recorder?.pause()
            case "finish": recorder?.finish()
            case "panelProfile":
                panelTab = .profile
                panelDetent = .medium
            case "filterCycle":
                kindFilter = [.poi]
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { kindFilter = [] }
            case "filterPoi":
                kindFilter = [.poi]
            case "filterNone":
                kindFilter = []
            case "profileScrub":
                // Expanded, day-scoped, with a point picked on the chart —
                // the state the readout exists for.
                dayScope = 4
                panelTab = .profile
                panelDetent = .expanded
                NotificationCenter.default.post(
                    name: Notification.Name("ULPDebugScrub"), object: nil,
                    userInfo: ["fraction": 0.42]
                )
            case "profileZoom":
                dayScope = 4
                panelTab = .profile
                panelDetent = .expanded
                NotificationCenter.default.post(
                    name: Notification.Name("ULPDebugScrub"), object: nil,
                    userInfo: ["fraction": 0.42, "zoom": 6.0, "snap": true]
                )
            case "zoomNote":
                // A landmark that carries a note, close enough in for both the
                // marker and the note to be showing.
                if let poi = package.checkpoints.first(where: {
                    $0.checkpointKind == .poi && !$0.note.isEmpty
                }) {
                    NotificationCenter.default.post(
                        name: Notification.Name("ULPDebugFocus"), object: nil,
                        userInfo: ["lat": poi.lat, "lng": poi.lng, "zoom": 16.6]
                    )
                }
            case "dayScope":
                dayScope = 4
                panelTab = .profile
                panelDetent = .medium
            case "dayScopeStops":
                dayScope = 4
                panelTab = .stops
                panelDetent = .medium
            case "zoomStop":
                // An overnight stop, where the pins and their names crowd.
                if let stop = package.checkpoints.first(where: { $0.checkpointKind == .overnight }) {
                    NotificationCenter.default.post(
                        name: Notification.Name("ULPDebugFocus"), object: nil,
                        userInfo: ["lat": stop.lat, "lng": stop.lng, "zoom": 13.5]
                    )
                }
            case "zoomOut":
                if let point = package.plannedRoute.segments.first?.points.first {
                    NotificationCenter.default.post(
                        name: Notification.Name("ULPDebugFocus"), object: nil,
                        userInfo: ["lat": point.lat, "lng": point.lng, "zoom": 13.0]
                    )
                }
            case "zoomStart":
                // Close in on the first point of the route, where the loop's
                // start/finish badge sits.
                if let point = package.plannedRoute.segments.first?.points.first {
                    NotificationCenter.default.post(
                        name: Notification.Name("ULPDebugFocus"), object: nil,
                        userInfo: ["lat": point.lat, "lng": point.lng, "zoom": 15.0]
                    )
                }
            case "panelStops":
                panelTab = .stops
                panelDetent = .medium
            case "panelNote":
                // Opening a stop's note is what a tap on the map does; a
                // headless run has no way to synthesise that tap.
                panelTab = .stops
                panelDetent = .expanded
                selectedCheckpoint = package.checkpoints.first { !$0.note.isEmpty }
            default: break
            }
        }
    }
    #endif
}
