import MapKit
import Network
import SwiftUI
import TripCore

/// A trip or a recorded walk on Apple's 3D terrain, for looking at before and
/// after — never during.
///
/// The offline map the trail screen uses cannot raise a mountain: MapLibre
/// Native draws hillshade and colour relief, both flat. Apple's realistic
/// elevation does, over satellite imagery, and covers the ground that matters
/// (checked on Mont Blanc, Zermatt and Fansipan). The price is that it streams
/// from Apple's servers, which is exactly what the walk itself must never do.
/// So this screen is fenced off from walking:
///
///   * it exists only while open — nothing is created, fetched or cached until
///     the walker taps 3D, and closing it ends everything;
///   * it cannot be opened while a walk is recording or paused (the callers
///     disable the button), so it can never compete with the walk for battery
///     or radio;
///   * the flyover runs only when asked, and stops on leaving the screen or the
///     app going to the background;
///   * without a connection it says so instead of showing an empty globe.
struct Overview3DView: View {
    struct Stretch: Identifiable, Hashable {
        let id: String
        let title: String
        let path: [CLLocationCoordinate2D]

        static func == (a: Stretch, b: Stretch) -> Bool { a.id == b.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    let title: String
    /// The planned route, drawn in green.
    let route: [CLLocationCoordinate2D]
    /// A recorded walk, drawn in orange over the plan; empty when previewing.
    var track: [[CLLocationCoordinate2D]] = []
    /// What the camera frames and flies along. The first is the default.
    let stretches: [Stretch]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Stretch?
    @State private var position: MapCameraPosition = .automatic
    @State private var flight: Task<Void, Never>?
    @State private var online = true
    @State private var monitor: NWPathMonitor?
    /// The camera's heading, so the direction chevrons — drawn upright by
    /// SwiftUI — can be turned to point along the line on the map.
    @State private var cameraHeading: Double = 0
    /// Built once per stretch, not per redraw — recomputing over an
    /// 8,500-point route on every camera move would be waste.
    @State private var chevronList: [Chevron] = []
    /// The framing camera, re-applied once the map is ready. Measured: a
    /// camera set before the map has loaded is clamped to 30–35° whatever was
    /// asked for, so the angle this screen requested on opening had never been
    /// used — which is why tilting felt so limited.
    @State private var pendingCamera: MapCamera?
    @State private var currentPitch: Double = 0
    /// The re-asks after a clamp, and the camera they ask for. Cancelled the
    /// moment the camera goes anywhere they did not send it: a re-ask landing
    /// mid-gesture snapped the walker's own tilt or pan back to the framing.
    @State private var retry: Task<Void, Never>?
    @State private var retryCamera: MapCamera?

    /// The app's own green, as on the 2D map; the white halo under it is what
    /// lifts it off the satellite imagery, not a brighter colour.
    private static let routeColour = Color(uiColor: .brandOnMap)
    private static let trackColour = Color.orange

    private var current: Stretch? { selection ?? stretches.first }

    /// The longest stretch worth flying. A flight lasts at most a minute, so
    /// beyond this the camera outruns Apple's terrain — the first try over the
    /// whole Tour du Mont Blanc reached a grey grid a third of the way round —
    /// and streams a whole region's imagery for the privilege. One day of a
    /// long trip fits comfortably; the whole trip is framed, not flown.
    static let maxFlightM = 30_000.0

    private var currentLengthM: Double {
        guard let path = current?.path else { return 0 }
        return Self.length(of: path)
    }

    private var canFly: Bool {
        (current?.path.count ?? 0) >= 2 && currentLengthM <= Self.maxFlightM
    }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                // Every line: a solid colour line over a white halo that lifts
                // it off the imagery. On a replay the plan steps back and the
                // walk is the line in front.
                if route.count >= 2 {
                    MapPolyline(coordinates: route)
                        .stroke(.white.opacity(track.isEmpty ? 0.9 : 0.55),
                                style: StrokeStyle(lineWidth: track.isEmpty ? 9 : 6, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: route)
                        .stroke(Self.routeColour.opacity(track.isEmpty ? 1 : 0.6),
                                style: StrokeStyle(lineWidth: track.isEmpty ? 5 : 3, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array(track.enumerated()), id: \.offset) { _, segment in
                    if segment.count >= 2 {
                        MapPolyline(coordinates: segment)
                            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: segment)
                            .stroke(Self.trackColour, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    }
                }
                // Static arrows on the line say which way. Turned against the
                // camera's heading, because SwiftUI draws them upright.
                ForEach(chevronList) { chevron in
                    Annotation("", coordinate: chevron.coordinate, anchor: .center) {
                        Self.chevron()
                            .rotationEffect(.degrees(chevron.bearing - cameraHeading))
                    }
                    .annotationTitles(.hidden)
                }
                if let first = current?.path.first {
                    Annotation("Start", coordinate: first) { Self.dot(.white) }
                }
                if let last = current?.path.last {
                    Annotation("End", coordinate: last) { Self.dot(.black) }
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .onMapCameraChange(frequency: .continuous) { context in
                cameraHeading = context.camera.heading
                currentPitch = context.camera.pitch
                if let asked = retryCamera, Self.movedByHand(context.camera, from: asked) { stopRetry() }
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                // The map first echoes the requested camera, then clamps it as
                // it finishes loading, and keeps clamping for a moment after.
                // Once the clamp is seen, ask again a few times, further apart
                // each time, until the angle holds. Only close in: beyond
                // 2.5 km the clamp is Apple's real limit, and asking again
                // achieves nothing but yanking the camera.
                guard let camera = pendingCamera, context.camera.pitch < camera.pitch - 1 else { return }
                pendingCamera = nil
                currentPitch = context.camera.pitch
                guard camera.distance <= Self.steepTiltM else { return }
                retryCamera = camera
                retry = Task { @MainActor in
                    for (attempt, delay) in [0.5, 1.0, 2.0, 3.0].enumerated() {
                        try? await Task.sleep(for: .seconds(delay))
                        if Task.isCancelled || currentPitch >= camera.pitch - 1 || flight != nil { break }
                        // A camera equal to the one already in `position` is
                        // not a change as far as SwiftUI is concerned, so the
                        // map is never told. Nudge the distance so it is.
                        var again = camera
                        again.distance *= 1 + 0.001 * Double(attempt + 1)
                        withAnimation(.easeInOut(duration: 0.8)) { position = .camera(again) }
                    }
                    retryCamera = nil
                    retry = nil
                }
            }
            .mapControls {
                MapCompass()
                MapPitchToggle()
            }
            // Keep the map's own controls below the title bar, not in the
            // status bar where the edge-to-edge map would put them.
            .safeAreaPadding(.top, 56)
            .ignoresSafeArea()

            header
        }
        .safeAreaInset(edge: .bottom) { footer }
        .onAppear {
            refreshDirection()
            frame(current)
            watchConnection()
            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-uiTestStretch"), i + 1 < args.count,
               let n = Int(args[i + 1]), stretches.indices.contains(n) {
                selection = stretches[n]
            }
            if args.contains("-uiTestFly") {
                Task { try? await Task.sleep(for: .seconds(3)); startFlight() }
            }
            #endif
        }
        .onDisappear {
            stopFlight()
            stopRetry()
            monitor?.cancel()
            monitor = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopFlight() }
        }
        .onChange(of: selection) { _, stretch in
            stopFlight()
            refreshDirection()
            frame(stretch)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Close 3D view")
                Spacer()
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                Spacer()
                Color.clear.frame(width: 40, height: 40)
            }
            if !online {
                Label("No connection — Apple's 3D map needs one", systemImage: "wifi.slash")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange, in: Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if stretches.count > 1 {
                Picker("Show", selection: Binding(
                    get: { current ?? stretches[0] },
                    set: { selection = $0 }
                )) {
                    ForEach(stretches) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer()
            }
            if flight == nil, !canFly, currentLengthM > Self.maxFlightM {
                Text("Pick a day to fly along")
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
            } else {
                Button {
                    flight == nil ? startFlight() : stopFlight()
                } label: {
                    Label(flight == nil ? "Fly along" : "Stop", systemImage: flight == nil ? "play.fill" : "stop.fill")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
                .disabled(flight == nil && !canFly)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - Direction

    struct Chevron: Identifiable {
        let id: Int
        let coordinate: CLLocationCoordinate2D
        let bearing: Double
    }

    /// What carries the direction: the walk on a replay, the chosen stretch on
    /// a preview.
    private var directedPath: [CLLocationCoordinate2D] {
        track.isEmpty ? (current?.path ?? []) : track.flatMap { $0 }
    }

    private func refreshDirection() {
        chevronList = Self.chevrons(along: directedPath)
    }

    /// Arrows spaced evenly along a path, about fourteen whatever its length:
    /// enough to read the direction anywhere along it, few enough not to turn
    /// an 800 m walk into a row of arrows.
    private static func chevrons(along path: [CLLocationCoordinate2D]) -> [Chevron] {
        guard path.count >= 2 else { return [] }
        let total = Self.length(of: path)
        guard total > 0 else { return [] }
        let spacing = total / 14
        var result: [Chevron] = []
        var travelled = 0.0, next = spacing / 2
        for (i, (a, b)) in zip(path, path.dropFirst()).enumerated() {
            let step = ActivityJournal.haversine(a.latitude, a.longitude, b.latitude, b.longitude)
            while step > 0, travelled + step >= next {
                let f = (next - travelled) / step
                let here = CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                                  longitude: a.longitude + (b.longitude - a.longitude) * f)
                // Heading from a point a little further on, so one wiggle in a
                // GPS track does not turn the arrow sideways.
                let ahead = path[min(i + 3, path.count - 1)]
                result.append(Chevron(id: result.count, coordinate: here, bearing: Self.bearing(here, ahead)))
                next += spacing
            }
            travelled += step
        }
        return result
    }

    /// A white chevron sitting on the line, like the arrows on the 2D map: it
    /// reads against the coloured line, and its shadow against the imagery
    /// where the line bends away beneath it.
    private static func chevron() -> some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 1.5)
    }

    private static func dot(_ colour: Color) -> some View {
        Circle()
            .fill(colour)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.brand, lineWidth: 3))
    }

    // MARK: - Camera

    /// Frame a stretch from an angle, so the relief reads at first sight.
    ///
    /// Apple caps the tilt by how far away the camera is — measured in this
    /// view: 70° within about 1 km, 60° out to 2.5 km, 35° beyond 3 km. A
    /// whole day fits only from far enough that 35° is all there is; pinching
    /// in is what unlocks the steeper angles, and the cap follows the zoom.
    private func frame(_ stretch: Stretch?) {
        guard let path = stretch?.path, let first = path.first else { return }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for p in path {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLng = min(minLng, p.longitude); maxLng = max(maxLng, p.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = ActivityJournal.haversine(minLat, minLng, maxLat, maxLng)
        let camera = MapCamera(centerCoordinate: center, distance: max(1_200, span * 2.4), heading: 0, pitch: 60)
        stopRetry()
        position = .camera(camera)
        pendingCamera = camera
    }

    /// The farthest the camera can be and still be allowed 60°.
    static let steepTiltM = 2_500.0

    private func stopRetry() {
        retry?.cancel()
        retry = nil
        retryCamera = nil
    }

    /// A camera the re-asks did not produce: turned, panned or zoomed. The
    /// clamp lowers the pitch and pulls the camera in by about 2% (measured),
    /// and the re-asks nudge the distance by a fraction of a percent.
    private static func movedByHand(_ camera: MapCamera, from asked: MapCamera) -> Bool {
        var turn = abs(camera.heading - asked.heading).truncatingRemainder(dividingBy: 360)
        if turn > 180 { turn = 360 - turn }
        let shift = ActivityJournal.haversine(camera.centerCoordinate.latitude, camera.centerCoordinate.longitude,
                                              asked.centerCoordinate.latitude, asked.centerCoordinate.longitude)
        return turn > 1
            || abs(camera.distance / asked.distance - 1) > 0.05
            || shift > asked.distance * 0.01
            || camera.pitch > asked.pitch + 1
    }

    /// Fly the camera along the stretch: a fixed number of hops with an
    /// animated move between each, heading where the path goes next. A long
    /// day is covered faster than a short walk, so either takes under a minute.
    private func startFlight() {
        guard canFly, let path = current?.path else { return }
        stopRetry()
        let samples = Self.resample(path, count: 90)
        let length = Self.length(of: path)
        let seconds = min(60, max(20, length / 120))
        let hop = seconds / Double(samples.count)
        // Kept within 2.4 km, where Apple allows 60°: higher than that the tilt
        // is capped at 35° and the flight is little more than a moving plan
        // view. 60° rather than steeper so the ridge beside the path does not
        // stand between the camera and the line it is following.
        let altitude = min(2_400, max(900, length / 6))

        flight = Task { @MainActor in
            var heading = Self.bearing(samples[0], samples[min(3, samples.count - 1)])
            for i in samples.indices {
                if Task.isCancelled { break }
                let ahead = samples[min(i + 3, samples.count - 1)]
                if i + 1 < samples.count {
                    heading = Self.turn(from: heading, to: Self.bearing(samples[i], ahead), by: 25)
                }
                withAnimation(.linear(duration: hop)) {
                    position = .camera(MapCamera(centerCoordinate: samples[i], distance: altitude, heading: heading, pitch: 60))
                }
                try? await Task.sleep(for: .seconds(hop))
            }
            flight = nil
        }
    }

    private func stopFlight() {
        flight?.cancel()
        flight = nil
    }

    private static func length(of path: [CLLocationCoordinate2D]) -> Double {
        zip(path, path.dropFirst()).reduce(0.0) {
            $0 + ActivityJournal.haversine($1.0.latitude, $1.0.longitude, $1.1.latitude, $1.1.longitude)
        }
    }

    private static func resample(_ path: [CLLocationCoordinate2D], count: Int) -> [CLLocationCoordinate2D] {
        guard path.count > count else { return path }
        return (0..<count).map { path[Int(Double($0) / Double(count - 1) * Double(path.count - 1))] }
    }

    private static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        TripPackage.bearing(fromLat: a.latitude, fromLng: a.longitude, toLat: b.latitude, toLng: b.longitude)
    }

    /// Turn toward a new heading by at most `limit` degrees, so the camera does
    /// not whip round on every switchback.
    private static func turn(from: Double, to: Double, by limit: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return (from + max(-limit, min(limit, delta)) + 360).truncatingRemainder(dividingBy: 360)
    }

    // MARK: - Connection

    /// Watched only while this screen is open.
    private func watchConnection() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in online = ok }
        }
        monitor.start(queue: DispatchQueue(label: "overview3d.path"))
        self.monitor = monitor
    }
}

extension Overview3DView {
    /// The planned route as a coordinate list, and a stretch per walking day.
    static func preview(of package: TripPackage) -> Overview3DView {
        let route = package.plannedRoute.segments.flatMap { $0.points }
            .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        let index = RouteIndex(segments: package.plannedRoute.segments)
        var stretches = [Stretch(id: "all", title: "Whole trip", path: route)]
        // Numbered as the trip screen numbers them: rest and travel days take a
        // number too, so a day here is the same day as on the list.
        for case let .walking(day, number) in Itinerary.combined(package) where day.endRouteM > day.startRouteM {
            let start = Double(day.startRouteM), end = Double(day.endRouteM)
            let steps = max(2, Int((end - start) / 50))
            let path = (0...steps).compactMap { i -> CLLocationCoordinate2D? in
                index.position(atRouteDistance: start + (end - start) * Double(i) / Double(steps))
                    .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
            }
            stretches.append(Stretch(id: "day-\(day.index)", title: "\(number) · " + Itinerary.Entry.walking(day, number: number).title, path: path))
        }
        return Overview3DView(title: package.trip.name, route: route, stretches: stretches)
    }
}
