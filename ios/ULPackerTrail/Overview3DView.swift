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

    private var current: Stretch? { selection ?? stretches.first }

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                if route.count >= 2 {
                    MapPolyline(coordinates: route)
                        .stroke(Color.brand.opacity(track.isEmpty ? 0.95 : 0.6), lineWidth: 4)
                }
                ForEach(Array(track.enumerated()), id: \.offset) { _, segment in
                    if segment.count >= 2 {
                        MapPolyline(coordinates: segment).stroke(.orange, lineWidth: 4)
                    }
                }
                if let first = current?.path.first {
                    Annotation("Start", coordinate: first) { Self.dot(.white) }
                }
                if let last = current?.path.last {
                    Annotation("End", coordinate: last) { Self.dot(.black) }
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
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
            frame(current)
            watchConnection()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiTestFly") {
                Task { try? await Task.sleep(for: .seconds(3)); startFlight() }
            }
            #endif
        }
        .onDisappear {
            stopFlight()
            monitor?.cancel()
            monitor = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stopFlight() }
        }
        .onChange(of: selection) { _, stretch in
            stopFlight()
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
            .disabled((current?.path.count ?? 0) < 2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
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
        guard let path = current?.path, path.count >= 2 else { return }
        let samples = Self.resample(path, count: 90)
        let length = zip(path, path.dropFirst()).reduce(0.0) {
            $0 + ActivityJournal.haversine($1.0.latitude, $1.0.longitude, $1.1.latitude, $1.1.longitude)
        }
        let seconds = min(60, max(20, length / 120))
        let hop = seconds / Double(samples.count)
        let altitude = min(4_000, max(700, length / 6))

        flight = Task { @MainActor in
            var heading = Self.bearing(samples[0], samples[min(3, samples.count - 1)])
            for i in samples.indices {
                if Task.isCancelled { break }
                let ahead = samples[min(i + 3, samples.count - 1)]
                if i + 1 < samples.count {
                    heading = Self.turn(from: heading, to: Self.bearing(samples[i], ahead), by: 25)
                }
                withAnimation(.linear(duration: hop)) {
                    position = .camera(MapCamera(centerCoordinate: samples[i], distance: altitude, heading: heading, pitch: 65))
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
            stretches.append(Stretch(id: "day-\(day.index)", title: "Day \(number): \(day.startName) → \(day.endName)", path: path))
        }
        return Overview3DView(title: package.trip.name, route: route, stretches: stretches)
    }
}
