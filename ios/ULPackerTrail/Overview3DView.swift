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
    /// A point of light travelling along the line toward its end — the
    /// direction of travel, shown without redrawing any line. Moving the
    /// dashes themselves looked right and cost 123 % CPU in the simulator
    /// against 0 % static: Apple's map rests when nothing changes, and a line
    /// restyled thirty times a second never lets it.
    @State private var cometIndex = 0
    @State private var marching: Task<Void, Never>?
    /// The camera's heading, so the direction chevrons — drawn upright by
    /// SwiftUI — can be turned to point along the line on the map.
    @State private var cameraHeading: Double = 0
    /// Built once per stretch, not per frame: the dashes step thirty times a
    /// second, and recomputing arrows over an 8,500-point route each time —
    /// or redrawing that route to move its dashes — would spend the battery
    /// the rest of this screen is careful not to.
    @State private var chevronList: [Chevron] = []
    /// A light copy (≤ 600 points) of what is being shown, the only line that
    /// is redrawn as its dashes move.
    @State private var movingPath: [CLLocationCoordinate2D] = []

    /// On satellite imagery the planner's dark green disappears into forest.
    /// A brighter green over a white halo reads on rock, ice and trees alike.
    private static let routeColour = Color(red: 0.20, green: 0.86, blue: 0.47)
    private static let trackColour = Color.orange
    private static let dash: [CGFloat] = [10, 8]

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
                // Every line: a white halo that separates it from the imagery,
                // a faint solid line, and — on what is being shown — bright
                // dashes travelling toward its end, the direction of travel.
                // The full-detail lines are static; only the light moving copy
                // is redrawn as the dashes step.
                if route.count >= 2 {
                    MapPolyline(coordinates: route)
                        .stroke(.white.opacity(track.isEmpty ? 0.9 : 0.55),
                                style: StrokeStyle(lineWidth: track.isEmpty ? 8 : 6, lineCap: .round, lineJoin: .round))
                    MapPolyline(coordinates: route)
                        .stroke(Self.routeColour.opacity(0.5),
                                style: StrokeStyle(lineWidth: track.isEmpty ? 4 : 3, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array(track.enumerated()), id: \.offset) { _, segment in
                    if segment.count >= 2 {
                        MapPolyline(coordinates: segment)
                            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                        MapPolyline(coordinates: segment)
                            .stroke(Self.trackColour.opacity(0.5), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                }
                if movingPath.count >= 2 {
                    MapPolyline(coordinates: movingPath)
                        .stroke(track.isEmpty ? Self.routeColour : Self.trackColour,
                                style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round, dash: Self.dash))
                    Annotation("", coordinate: movingPath[min(cometIndex, movingPath.count - 1)], anchor: .center) {
                        Self.comet(colour: track.isEmpty ? Self.routeColour : Self.trackColour)
                    }
                    .annotationTitles(.hidden)
                }
                ForEach(chevronList) { chevron in
                    Annotation("", coordinate: chevron.coordinate, anchor: .center) {
                        Self.chevron(colour: track.isEmpty ? Self.routeColour : Self.trackColour)
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
            startMarching()
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
            stopMarching()
            monitor?.cancel()
            monitor = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                stopFlight()
                stopMarching()
            } else {
                startMarching()
            }
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
        let path = directedPath
        movingPath = Self.resample(path, count: 600)
        cometIndex = 0
        chevronList = Self.chevrons(along: path)
    }

    /// Arrows spaced evenly along a path, about ten whatever its length — the
    /// dashes and the moving light carry the line; the arrows only need to say
    /// which way. Two dozen crowded an 800 m walk with one every 30 m.
    private static func chevrons(along path: [CLLocationCoordinate2D]) -> [Chevron] {
        guard path.count >= 2 else { return [] }
        let total = Self.length(of: path)
        guard total > 0 else { return [] }
        let spacing = total / 10
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

    private static func comet(colour: Color) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 13, height: 13)
            .shadow(color: .white, radius: 4)
            .shadow(color: colour, radius: 8)
            .shadow(color: colour.opacity(0.9), radius: 16)
    }

    private static func chevron(colour: Color) -> some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 10, weight: .black))
            .foregroundStyle(colour)
            .frame(width: 17, height: 17)
            .background(Circle().fill(.white.opacity(0.92)))
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }

    /// Move the light along the line, start to end, then again: a few hops a
    /// second, each animated, so the motion is smooth without the map being
    /// asked for a frame of its own. Only while this screen is open and the app
    /// is in front — it is decoration, and decoration does not get to spend
    /// battery in a pocket.
    private func startMarching() {
        guard marching == nil, movingPath.count >= 2 else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-noMarch") { return }
        #endif
        let count = movingPath.count
        let hop = 0.4
        let step = max(1, count / 40)   // once along in about 16 s
        marching = Task { @MainActor in
            while !Task.isCancelled {
                if cometIndex + step >= count {
                    cometIndex = 0
                } else {
                    withAnimation(.linear(duration: hop)) { cometIndex += step }
                }
                try? await Task.sleep(for: .seconds(hop))
            }
        }
    }

    private func stopMarching() {
        marching?.cancel()
        marching = nil
    }

    private static func dot(_ colour: Color) -> some View {
        Circle()
            .fill(colour)
            .frame(width: 14, height: 14)
            .overlay(Circle().stroke(Color.brand, lineWidth: 3))
    }

    // MARK: - Camera

    /// Frame a stretch from an angle, so the relief reads at first sight.
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
        position = .camera(MapCamera(centerCoordinate: center, distance: max(1_200, span * 2.4), heading: 0, pitch: 55))
    }

    /// Fly the camera along the stretch: a fixed number of hops with an
    /// animated move between each, heading where the path goes next. A long
    /// day is covered faster than a short walk, so either takes under a minute.
    private func startFlight() {
        guard canFly, let path = current?.path else { return }
        let samples = Self.resample(path, count: 90)
        let length = Self.length(of: path)
        let seconds = min(60, max(20, length / 120))
        let hop = seconds / Double(samples.count)
        // Higher and less steep than the framing view: in the Alps the ridge
        // beside the path stood between a 65° camera and the line it was
        // following, and the route vanished behind it.
        let altitude = min(3_500, max(900, length / 5))

        flight = Task { @MainActor in
            var heading = Self.bearing(samples[0], samples[min(3, samples.count - 1)])
            for i in samples.indices {
                if Task.isCancelled { break }
                let ahead = samples[min(i + 3, samples.count - 1)]
                if i + 1 < samples.count {
                    heading = Self.turn(from: heading, to: Self.bearing(samples[i], ahead), by: 25)
                }
                withAnimation(.linear(duration: hop)) {
                    position = .camera(MapCamera(centerCoordinate: samples[i], distance: altitude, heading: heading, pitch: 52))
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
