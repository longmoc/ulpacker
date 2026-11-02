import MapKit
import SwiftUI
import TripCore

/// The map behind `Overview3DView`: Apple's 3D terrain, driven through UIKit's
/// `MKMapView` rather than SwiftUI's `Map`, so that a flight can draw the day
/// as it goes. Filmed frame by frame on the simulator:
///
///   * with SwiftUI, a line replaced as it grew was laid onto the terrain only
///     every 0.4 s or so, so it stepped; and the camera, animated by SwiftUI
///     whatever it is asked, trailed the flight by half a kilometre;
///   * with UIKit, a line replaced every 0.1 s shows every time, and the
///     camera, set outright every frame, is exactly where the flight puts it.
///
/// Growing one line with `MKPolylineRenderer.strokeEnd` instead was smooth
/// only with the camera still: with it moving, by any means, the map put off
/// redrawing an existing overlay for about 2 s at a time. So whatever must
/// change while the camera moves is replaced, never redrawn.
///
/// The imagery, terrain and labels are the same map either way.
///
/// Everything drawn on it is an overlay, marks included. Annotations sit at
/// sea level and, on realistic terrain, under the ground: in the Alps the map
/// never asked for a single annotation view, while the same marks over Hanoi,
/// or over the Alps drawn flat, all showed (measured). Overlays are laid onto
/// the terrain itself.
@MainActor
@Observable
final class Overview3DMap: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
    @ObservationIgnored let mapView = MKMapView()
    private(set) var flying = false
    /// Off the vertical, for the 2D/3D button.
    private(set) var tilted = false

    override init() {
        super.init()
        mapView.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
        mapView.delegate = self
        mapView.showsCompass = true
        installGestures()
    }

    // MARK: - Content

    /// A line on the map and how to stroke it. A coloured line is two of
    /// these: a wider white one beneath, the halo that lifts it off the
    /// imagery, and the colour over it.
    final class Line: MKPolyline {
        var colour: UIColor = .white
        var width: CGFloat = 1
        var alpha: CGFloat = 1
        /// Part of what a flight flies along, faded back while it does.
        var flyable = false
    }

    /// A symbol on the ground: start, end, a direction arrow.
    final class Mark: NSObject, MKOverlay {
        let image: UIImage
        let coordinate: CLLocationCoordinate2D
        /// Arrows lie along the line, so they turn with the map; start and end
        /// are drawn turned by the camera's heading, to stand upright on screen.
        let bearing: Double
        /// Whatever the mark is drawn over, at any zoom: wide, because a mark
        /// keeps its size on screen and so covers kilometres when zoomed out.
        let boundingMapRect: MKMapRect

        init(_ image: UIImage, at coordinate: CLLocationCoordinate2D, bearing: Double) {
            self.image = image
            self.coordinate = coordinate
            self.bearing = bearing
            let reach = MKMapPointsPerMeterAtLatitude(coordinate.latitude) * 40_000
            let p = MKMapPoint(coordinate)
            boundingMapRect = MKMapRect(x: p.x - reach, y: p.y - reach, width: reach * 2, height: reach * 2)
        }
    }

    /// Draws a mark at a fixed size on screen, centred on its coordinate.
    final class MarkRenderer: MKOverlayRenderer {
        override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
            guard let mark = overlay as? Mark else { return }
            let image = mark.image
            let size = CGSize(width: image.size.width / zoomScale, height: image.size.height / zoomScale)
            let centre = point(for: MKMapPoint(mark.coordinate))
            let bounds = CGRect(x: centre.x - size.width, y: centre.y - size.height,
                                width: size.width * 2, height: size.height * 2)
            guard rect(for: mapRect).intersects(bounds) else { return }
            UIGraphicsPushContext(context)
            context.saveGState()
            context.translateBy(x: centre.x, y: centre.y)
            context.rotate(by: CGFloat(mark.bearing * .pi / 180))
            image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
            context.restoreGState()
            UIGraphicsPopContext()
        }
    }

    struct Content {
        var route: [CLLocationCoordinate2D]
        var track: [[CLLocationCoordinate2D]]
        var stretch: Overview3DView.Stretch?
        /// One day picked out of a planned trip: the rest of the trip steps
        /// back to a thin pale line.
        var pickedDay: Bool
    }

    @ObservationIgnored private var content: Content?
    /// Start and end, replaced as the camera turns to stay upright.
    @ObservationIgnored private var uprights: [Mark] = []
    /// The heading start and end were last drawn against.
    @ObservationIgnored private var drawnHeading = 0.0

    private static let routeColour = UIColor.brandOnMap
    private static let trackColour = UIColor.systemOrange

    func show(_ content: Content) {
        stopFlight()
        keepMapKitPanToOneFinger()
        self.content = content
        mapView.removeOverlays(mapView.overlays)

        let replay = !content.track.isEmpty
        var lines: [Line] = []
        // On a replay the plan steps back and the walk is the line in front;
        // with one day picked, the rest of the trip steps back and the day is
        // the line in front.
        if content.route.count >= 2 {
            if content.pickedDay {
                lines.append(Self.line(content.route, .white, width: 3, alpha: 0.85))
            } else {
                lines.append(Self.line(content.route, .white, width: replay ? 6 : 9, alpha: replay ? 0.55 : 0.9))
                lines.append(Self.line(content.route, Self.routeColour, width: replay ? 3 : 5, alpha: replay ? 0.6 : 1))
            }
        }
        if content.pickedDay, let day = content.stretch?.path, day.count >= 2 {
            lines.append(Self.line(day, .white, width: 11, flyable: true))
            lines.append(Self.line(day, Self.routeColour, width: 6, flyable: true))
        }
        for segment in content.track where segment.count >= 2 {
            lines.append(Self.line(segment, .white, width: 9, alpha: 0.9, flyable: true))
            lines.append(Self.line(segment, Self.trackColour, width: 5, flyable: true))
        }
        mapView.addOverlays(lines, level: .aboveRoads)

        // Static arrows on the line say which way: the walk on a replay, the
        // chosen stretch on a preview.
        let directed = replay ? content.track.flatMap { $0 } : (content.stretch?.path ?? [])
        if let arrow = Images.chevron {
            let arrows = Overview3DView.chevrons(along: directed).map { Mark(arrow, at: $0.coordinate, bearing: $0.bearing) }
            mapView.addOverlays(arrows, level: .aboveLabels)
        }
        uprights = []
        drawnHeading = mapView.camera.heading
        placeUprights()
    }

    private func placeUprights() {
        guard let path = content?.stretch?.path, let first = path.first, let last = path.last,
              let start = Images.start, let end = Images.end else { return }
        mapView.removeOverlays(uprights)
        uprights = [Mark(start, at: first, bearing: drawnHeading), Mark(end, at: last, bearing: drawnHeading)]
        mapView.addOverlays(uprights, level: .aboveLabels)
    }

    private static func line(_ path: [CLLocationCoordinate2D], _ colour: UIColor, width: CGFloat,
                             alpha: CGFloat = 1, flyable: Bool = false) -> Line {
        let line = Line(coordinates: path, count: path.count)
        line.colour = colour
        line.width = width
        line.alpha = alpha
        line.flyable = flyable
        return line
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if overlay is Mark { return MarkRenderer(overlay: overlay) }
        guard let line = overlay as? Line else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.strokeColor = line.colour
        renderer.lineWidth = line.width
        renderer.alpha = flying && line.flyable ? Self.fadedAlpha(line) : line.alpha
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }

    /// The SwiftUI-drawn marks, rendered once to images.
    private enum Images {
        @MainActor static let start = render(Overview3DView.endpoint("figure.walk", fill: Color(uiColor: .brandOnMap)))
        @MainActor static let end = render(Overview3DView.endpoint("flag.checkered", fill: .black))
        @MainActor static let chevron = render(Overview3DView.chevron().padding(3))

        @MainActor static func render(_ view: some View) -> UIImage? {
            let renderer = ImageRenderer(content: view)
            renderer.scale = UIScreen.main.scale
            return renderer.uiImage
        }
    }

    // MARK: - Camera

    /// The framing camera, asked again once the map is ready. Measured: a
    /// camera set before the map has loaded is clamped to 30–35° whatever was
    /// asked for. Dropped the moment the camera goes anywhere it did not send
    /// it, so a re-ask never snaps the walker's own tilt or pan back.
    @ObservationIgnored private var asked: MKMapCamera?
    @ObservationIgnored private var reAsks = 0
    @ObservationIgnored private var reAsk: Task<Void, Never>?

    /// The farthest the camera can be and still be allowed 60°.
    static let steepTiltM = 2_500.0

    /// Frame a stretch from an angle, so the relief reads at first sight.
    ///
    /// Apple caps the tilt by how far away the camera is — measured: 70°
    /// within about 1 km, 60° out to 2.5 km, 35° beyond 3 km. A whole day fits
    /// only from far enough that 35° is all there is; pinching in is what
    /// unlocks the steeper angles, and the cap follows the zoom.
    func frame(_ path: [CLLocationCoordinate2D], animated: Bool) {
        guard let first = path.first else { return }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for p in path {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLng = min(minLng, p.longitude); maxLng = max(maxLng, p.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2)
        let span = ActivityJournal.haversine(minLat, minLng, maxLat, maxLng)
        let camera = MKMapCamera(lookingAtCenter: center, fromDistance: max(1_200, span * 3), pitch: 60, heading: 0)
        stopReAsking()
        asked = camera.centerCoordinateDistance <= Self.steepTiltM ? camera : nil
        wantedPitch = camera.pitch
        mapView.setCamera(camera, animated: animated)
    }

    /// Flat or tilted, for the 2D/3D button.
    func toggleTilt() {
        stopReAsking()
        let camera = mapView.camera.copy() as! MKMapCamera
        camera.pitch = tilted ? 0 : 60
        wantedPitch = camera.pitch
        mapView.setCamera(camera, animated: true)
    }

    private func stopReAsking() {
        reAsk?.cancel()
        reAsk = nil
        asked = nil
        reAsks = 0
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        let camera = mapView.camera
        tilted = camera.pitch > 1
        turnUprights(to: camera.heading)
        if let asked, !flying, Self.movedByHand(camera, from: asked) { stopReAsking() }
    }

    /// Keep start and end upright on screen as the map turns under them, once
    /// the turn would show.
    private func turnUprights(to heading: Double) {
        var turn = abs(heading - drawnHeading).truncatingRemainder(dividingBy: 360)
        if turn > 180 { turn = 360 - turn }
        guard turn > 3 else { return }
        drawnHeading = heading
        placeUprights()
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        if asked == nil, !flying { holdPitch() }
        // The map clamps the angle as it finishes loading, and keeps clamping
        // for a moment after. Ask again a few times, further apart each time,
        // until the angle holds.
        guard let asked, !flying, mapView.camera.pitch < asked.pitch - 1, reAsks < 4, reAsk == nil else { return }
        let delay = [0.5, 1.0, 2.0, 3.0][reAsks]
        reAsks += 1
        reAsk = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, let asked = self.asked else { return }
            self.reAsk = nil
            self.mapView.setCamera(asked, animated: true)
        }
    }

    /// A camera the re-asks did not produce: turned, panned or zoomed. The
    /// clamp lowers the pitch and pulls the camera in by about 2% (measured).
    private static func movedByHand(_ camera: MKMapCamera, from asked: MKMapCamera) -> Bool {
        var turn = abs(camera.heading - asked.heading).truncatingRemainder(dividingBy: 360)
        if turn > 180 { turn = 360 - turn }
        let shift = ActivityJournal.haversine(camera.centerCoordinate.latitude, camera.centerCoordinate.longitude,
                                              asked.centerCoordinate.latitude, asked.centerCoordinate.longitude)
        return turn > 1
            || abs(camera.centerCoordinateDistance / asked.centerCoordinateDistance - 1) > 0.05
            || shift > asked.centerCoordinateDistance * 0.01
            || camera.pitch > asked.pitch + 1
    }

    // MARK: - Gestures

    /// MapKit's own two-finger gestures hold the tilt far below what the same
    /// map allows a camera set in code: from a flight at 60°, one twist of the
    /// fingers dropped it to 10–20° (on the phone). So pinch, twist and tilt
    /// are this map's own, and set the camera as a flight does; the only
    /// limit left is Apple's by distance (70° within about 1 km, 60° out to
    /// 2.5 km, 35° beyond 3 km). Dragging with one finger stays MapKit's.
    @ObservationIgnored private var wantedPitch = 60.0
    @ObservationIgnored private var holding = false
    @ObservationIgnored private var tiltGesture: UIPanGestureRecognizer?

    private func installGestures() {
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let twist = UIRotationGestureRecognizer(target: self, action: #selector(twisted(_:)))
        let tilt = UIPanGestureRecognizer(target: self, action: #selector(tilted(_:)))
        tilt.minimumNumberOfTouches = 2
        tilt.maximumNumberOfTouches = 2
        tiltGesture = tilt
        for gesture in [pinch, twist, tilt] as [UIGestureRecognizer] {
            gesture.delegate = self
            mapView.addGestureRecognizer(gesture)
        }
    }

    /// Two fingers moving together tilt; they must not also drag the map,
    /// which MapKit's own pan would do with any number of fingers.
    private func keepMapKitPanToOneFinger() {
        func visit(_ view: UIView) {
            for case let pan as UIPanGestureRecognizer in view.gestureRecognizers ?? [] where pan !== tiltGesture {
                pan.maximumNumberOfTouches = 1
            }
            view.subviews.forEach(visit)
        }
        visit(mapView)
    }

    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Changes the camera by `change`, unless a flight is flying it.
    private func adjust(_ change: (MKMapCamera) -> Void) {
        guard !flying else { return }
        stopReAsking()
        keepMapKitPanToOneFinger()
        let camera = mapView.camera.copy() as! MKMapCamera
        change(camera)
        mapView.camera = camera
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed, gesture.scale > 0 else { return }
        let scale = Double(gesture.scale)
        gesture.scale = 1
        adjust { $0.centerCoordinateDistance = min(400_000, max(300, $0.centerCoordinateDistance / scale)) }
    }

    @objc private func twisted(_ gesture: UIRotationGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let degrees = Double(gesture.rotation) * 180 / .pi
        gesture.rotation = 0
        adjust { $0.heading = ($0.heading - degrees + 360).truncatingRemainder(dividingBy: 360) }
    }

    @objc private func tilted(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let up = -Double(gesture.translation(in: mapView).y)
        gesture.setTranslation(.zero, in: mapView)
        // Fingers up tip the view toward the horizon, as in Maps.
        adjust { $0.pitch = min(80, max(0, $0.pitch + up * 0.3)) }
        wantedPitch = mapView.camera.pitch
    }

    /// After a gesture, if the map has flattened the view below the walker's
    /// chosen tilt, tilt it back, once; if it will not go back — zoomed out
    /// past what the tilt allows — that becomes the tilt.
    private func holdPitch() {
        guard !holding, mapView.camera.pitch < wantedPitch - 2 else { return }
        holding = true
        let camera = mapView.camera.copy() as! MKMapCamera
        camera.pitch = wantedPitch
        mapView.setCamera(camera, animated: true)
        // A camera the map clamps to where it already is reports no change,
        // so the outcome is read once the move has had time to finish.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.holding = false
            self.wantedPitch = min(self.wantedPitch, self.mapView.camera.pitch)
        }
    }

    // MARK: - Flight

    @ObservationIgnored private var clock: Overview3DView.FlightClock?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var startedAt: CFTimeInterval?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var heading = 0.0
    @ObservationIgnored private var altitude = 0.0
    @ObservationIgnored private var lookAhead = 0.0
    /// The part flown so far, drawn in full over the faded stretch; replaced
    /// as it grows.
    @ObservationIgnored private var flownLines: [Line] = []
    @ObservationIgnored private var flownAt: CFTimeInterval = 0
    @ObservationIgnored private var flownColour = UIColor.brandOnMap

    /// Fly the camera along `path`, drawing it as it goes: a glide down to the
    /// start, then an even pace to the end, under a minute for a long day.
    func startFlight(along path: [CLLocationCoordinate2D]) {
        guard path.count >= 2, let content else { return }
        stopFlight()
        stopReAsking()
        var clock = Overview3DView.FlightClock(path: path)
        clock.seconds = min(60, max(20, clock.length / 120))
        self.clock = clock
        // Kept within 2.4 km, where Apple allows 60°: higher than that the tilt
        // is capped at 35° and the flight is little more than a moving plan
        // view. 60° rather than steeper so the ridge beside the path does not
        // stand between the camera and the line it is following.
        altitude = min(2_400, max(900, clock.length / 6))
        lookAhead = clock.length / 50
        heading = Overview3DView.bearing(path[0], clock.point(atDistance: lookAhead))
        flownColour = content.track.isEmpty ? Self.routeColour : Self.trackColour
        flying = true

        // The stretch fades back; the flown line is drawn over it in full.
        // Set while the camera is still, so the fade is drawn straight away.
        for case let line as Line in mapView.overlays where line.flyable {
            (mapView.renderer(for: line) as? MKPolylineRenderer)?.alpha = Self.fadedAlpha(line)
        }

        // Down to the start first, slowly: in one short hop the map swooped in
        // over the middle of the day and only then turned to the start.
        let glide = MKMapCamera(lookingAtCenter: path[0], fromDistance: altitude, pitch: 60, heading: heading)
        UIView.animate(withDuration: 2.5, delay: 0, options: [.curveEaseInOut]) {
            self.mapView.camera = glide
        } completion: { [weak self] _ in
            guard let self, self.flying, self.link == nil else { return }
            let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    func stopFlight() {
        link?.invalidate()
        link = nil
        startedAt = nil
        clock = nil
        if !flownLines.isEmpty { mapView.removeOverlays(flownLines) }
        flownLines = []
        flownAt = 0
        if flying {
            for case let line as Line in mapView.overlays where line.flyable {
                (mapView.renderer(for: line) as? MKPolylineRenderer)?.alpha = line.alpha
            }
        }
        if flying { wantedPitch = mapView.camera.pitch }
        flying = false
    }

    private static func fadedAlpha(_ line: Line) -> CGFloat {
        line.colour == .white ? 0.5 : 0.4
    }

    /// A display link holds its target strongly; this keeps it from holding
    /// the map. Added to the main run loop, so it ticks on the main actor.
    @MainActor
    private final class Ticker: NSObject {
        weak var owner: Overview3DMap?
        init(_ owner: Overview3DMap) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }

    private func tick(_ link: CADisplayLink) {
        guard let clock else { return }
        let now = link.timestamp
        if startedAt == nil { startedAt = now; lastTick = now }
        let dt = min(0.1, now - lastTick)
        lastTick = now
        let elapsed = now - (startedAt ?? now)
        let d = clock.length * min(1, elapsed / clock.seconds)
        let here = clock.point(atDistance: d)

        // Turn toward where the path goes next, smoothly and at most 60° a
        // second; near the end there is nothing left to look ahead to, so hold.
        if d + lookAhead / 2 < clock.length {
            let want = Overview3DView.bearing(here, clock.point(atDistance: d + lookAhead))
            var delta = (want - heading).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            let step = max(-60 * dt, min(60 * dt, delta * min(1, 3 * dt)))
            heading = (heading + step + 360).truncatingRemainder(dividingBy: 360)
        }

        // A fresh line every 0.1 s, the new one added before the old goes so
        // there is never a frame without one.
        if now - flownAt >= 0.1 {
            flownAt = now
            let piece = clock.piece(from: 0, to: d)
            if piece.count >= 2 {
                let fresh = [Self.line(piece, .white, width: 11), Self.line(piece, flownColour, width: 6)]
                mapView.addOverlays(fresh, level: .aboveRoads)
                mapView.removeOverlays(flownLines)
                flownLines = fresh
            }
        }
        mapView.camera = MKMapCamera(lookingAtCenter: here, fromDistance: altitude, pitch: 60, heading: heading)

        // At the end, a moment on the finished line before it goes.
        if elapsed >= clock.seconds + 1.5 { stopFlight() }
    }
}

/// Hosts the map so its centre falls in the middle of what the screen's bars
/// leave visible. `MKMapView` centres the camera on its own bounds whatever
/// its safe area says (measured; SwiftUI's `Map` honoured safe area), so the
/// map is made taller than the screen, running off the top by the difference
/// between the bars: without it a day was centred on the whole screen and its
/// end tucked under the footer. The bars are still safe area, which keeps the
/// compass below the title bar.
struct Overview3DMapView: UIViewControllerRepresentable {
    let map: Overview3DMap
    let insets: UIEdgeInsets

    final class Controller: UIViewController {
        var map: MKMapView!
        var insets = UIEdgeInsets.zero { didSet { additionalSafeAreaInsets = insets } }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.addSubview(map)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // Safe area here already counts the bars.
            let lift = max(0, view.safeAreaInsets.bottom - view.safeAreaInsets.top)
            map.frame = CGRect(x: 0, y: -lift, width: view.bounds.width, height: view.bounds.height + lift)
        }
    }

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.map = map.mapView
        controller.insets = insets
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        if controller.insets != insets { controller.insets = insets }
    }
}
