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
                // No route distance while off the route, which is also what
                // turns the marker from a direction arrow into a plain dot:
                // the route cannot say which way the walker faces when it does
                // not know where they are on it.
                routeDistanceM: isOnRoute ? recorder.progress?.routeDistanceM : nil,
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

            if let banner = statusBanner {
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

    private var readouts: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Withheld rather than guessed while off the route entirely:
                // "28.26 km done" for someone who has not started walking is
                // worse than a dash.
                readout("Done", km(isOnRoute ? recorder.progress?.routeDistanceM : nil))
                Divider().frame(height: 44)
                readout("Left", km(isOnRoute ? recorder.progress?.remainingM : nil))
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

    private var controls: some View {
        Group {
            switch recorder.status {
            case .idle, .needsPermission:
                bigButton("Start trail", tint: .brand) { recorder.start() }
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
                    bigButton("Done", tint: .brand) { recorder.clearFinished() }
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

    private var currentCoordinate: CLLocationCoordinate2D? {
        // Snapped when the match is real, raw when it is not — and `Progress`
        // carries whichever one applies, so this only has to pass it through.
        //
        // Snapping exists because drawing the raw observation puts the walker
        // beside the line whenever GPS is noisy, which reads as a bug rather
        // than as noise. It stops being a correction and starts being a
        // fabrication once the fix is nowhere near the route, which the matcher
        // now refuses to project at all.
        guard let progress = recorder.progress else { return nil }
        return CLLocationCoordinate2D(latitude: progress.lat, longitude: progress.lng)
    }

    /// The route distances covered by the chosen day.
    private var scopeRange: ClosedRange<Double>? {
        guard let dayScope, let day = package.itinerary.first(where: { $0.index == dayScope })
        else { return nil }
        return Double(day.startRouteM)...Double(day.endRouteM)
    }

    /// Whether the position on screen is a place on this route.
    private var isOnRoute: Bool {
        recorder.progress?.confidence != .lost
    }

    private var statusBanner: (text: String, colour: Color)? {
        if let offRouteText { return (offRouteText, .red) }

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
    private var offRouteText: String? {
        guard !isOnRoute else { return nil }
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
