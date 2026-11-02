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
///
/// The map itself is `Overview3DMap`; this is the screen around it.
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
    @State private var map = Overview3DMap()
    @State private var selection: Stretch?
    @State private var online = true
    @State private var monitor: NWPathMonitor?
    /// The footer's height, given to the map as safe area so it frames into
    /// the part of the screen left visible.
    @State private var footerHeight: CGFloat = 0

    private var current: Stretch? { selection ?? stretches.first }

    /// A single day picked out of a planned trip.
    private var isPickedDay: Bool {
        track.isEmpty && current.map { $0.path.count >= 2 && $0.id != stretches.first?.id } == true
    }

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
            // The map's own controls sit below the title bar, not in the
            // status bar where the edge-to-edge map would put them.
            Overview3DMapView(map: map, insets: UIEdgeInsets(top: 56, left: 0, bottom: footerHeight, right: 0))
                .ignoresSafeArea()
            header
        }
        .safeAreaInset(edge: .bottom) { footer }
        .onAppear {
            show(animated: false)
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
            map.stopFlight()
            monitor?.cancel()
            monitor = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { map.stopFlight() }
        }
        .onChange(of: selection) {
            show(animated: true)
        }
    }

    private func show(animated: Bool) {
        map.show(.init(route: route, track: track, stretch: current, pickedDay: isPickedDay))
        map.frame(current?.path ?? [], animated: animated)
    }

    private func startFlight() {
        guard canFly, let path = current?.path else { return }
        map.startFlight(along: path)
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
                // UIKit's map has no 2D/3D control on iOS, so this one stands
                // in for SwiftUI's.
                Button { map.toggleTilt() } label: {
                    Text(map.tilted ? "2D" : "3D")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel(map.tilted ? "Show flat" : "Show in 3D")
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
            if !map.flying, !canFly, currentLengthM > Self.maxFlightM {
                Text("Pick a day to fly along")
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
            } else {
                Button {
                    map.flying ? map.stopFlight() : startFlight()
                } label: {
                    Label(map.flying ? "Stop" : "Fly along", systemImage: map.flying ? "stop.fill" : "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.brand)
                .disabled(!map.flying && !canFly)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
    }

    // MARK: - Direction

    struct Chevron {
        let id: Int
        let coordinate: CLLocationCoordinate2D
        let bearing: Double
    }

    /// Arrows spaced evenly along a path, about fourteen whatever its length:
    /// enough to read the direction anywhere along it, few enough not to turn
    /// an 800 m walk into a row of arrows.
    static func chevrons(along path: [CLLocationCoordinate2D]) -> [Chevron] {
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
    static func chevron() -> some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 1.5)
    }

    /// Start and end of the stretch: big enough to find from a whole day
    /// away, and told apart by their symbol, not only their colour.
    static func endpoint(_ symbol: String, fill: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(fill, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    // MARK: - Flight

    /// A path measured along the ground, for a flight along it at an even
    /// pace.
    struct FlightClock {
        let path: [CLLocationCoordinate2D]
        /// Distance from the start to each point of `path`.
        let along: [Double]
        var seconds = 1.0

        init(path: [CLLocationCoordinate2D]) {
            self.path = path
            var along = [0.0]
            for (a, b) in zip(path, path.dropFirst()) {
                along.append(along[along.count - 1] + ActivityJournal.haversine(a.latitude, a.longitude, b.latitude, b.longitude))
            }
            self.along = along
        }

        var length: Double { along.last ?? 0 }

        /// The path between two distances along it, ending exactly at each.
        func piece(from start: Double, to end: Double) -> [CLLocationCoordinate2D] {
            guard end > start else { return [] }
            let (i, _) = locate(start), (j, _) = locate(end)
            let inner = i < j ? Array(path[i..<j]) : []
            return [point(atDistance: start)] + inner + [point(atDistance: end)]
        }


        /// The point of `path` at or just beyond `distance`, and how far
        /// towards it from the one before.
        private func locate(_ distance: Double) -> (Int, Double) {
            let d = min(max(distance, 0), length)
            var lo = 0, hi = along.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if along[mid] < d { lo = mid + 1 } else { hi = mid }
            }
            guard lo > 0 else { return (0, 0) }
            let step = along[lo] - along[lo - 1]
            return (lo, step > 0 ? (d - along[lo - 1]) / step : 0)
        }

        func point(atDistance distance: Double) -> CLLocationCoordinate2D {
            let (i, f) = locate(distance)
            guard i > 0 else { return path[0] }
            let a = path[i - 1], b = path[i]
            return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * f,
                                          longitude: a.longitude + (b.longitude - a.longitude) * f)
        }
    }

    private static func length(of path: [CLLocationCoordinate2D]) -> Double {
        zip(path, path.dropFirst()).reduce(0.0) {
            $0 + ActivityJournal.haversine($1.0.latitude, $1.0.longitude, $1.1.latitude, $1.1.longitude)
        }
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        TripPackage.bearing(fromLat: a.latitude, fromLng: a.longitude, toLat: b.latitude, toLng: b.longitude)
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
