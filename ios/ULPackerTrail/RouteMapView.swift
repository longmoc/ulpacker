import MapLibre
import SwiftUI
import TripCore

/// The planned route on a map, with checkpoints and the walker's position.
///
/// MapLibre Native rather than MapKit: the point of this app is offline, and
/// MapLibre reads a local PMTiles file straight from disk. The style is a
/// remote demo one for now — swapping it for a bundled offline pack is M5 and
/// touches only `styleURL`, not the layers built here.
///
/// The route is added once as a GeoJSON source and then left alone. Everything
/// that changes per fix — the position dot — updates its own tiny source, so a
/// GPS update never rebuilds an 8560-point line.
struct RouteMapView: UIViewRepresentable {
    let package: TripPackage
    /// Current position, if the recorder has one.
    var position: CLLocationCoordinate2D?
    /// Where along the route the walker is, used to colour progress.
    var routeDistanceM: Double?
    /// How the camera behaves while recording.
    enum FollowMode {
        /// The map stays where it was panned.
        case free
        /// Centred on the walker, north up.
        case northUp
        /// Centred on the walker and turned so the route ahead points up.
        case courseUp
    }

    var followMode: FollowMode
    /// Kinds to show. Empty means all, matching the web planner.
    var kindFilter: Set<CheckpointKind> = []
    /// Raised when the walker's own gesture should change the camera mode —
    /// tapping the compass, or panning the map away.
    var onFollowModeOverride: ((FollowMode) -> Void)?
    /// Called when a checkpoint pin is tapped.
    var onSelectCheckpoint: ((TripPackage.Checkpoint, CGPoint) -> Void)?

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        // A local pack wins whenever one is installed. The remote style is a
        // development convenience only — on a trail there is no signal, and a
        // map that quietly needs some is worse than no map at all.
        mapView.styleURL = Self.styleURL(for: package)
        // Attribution and logo must stay reachable: OpenStreetMap's licence
        // requires it, and the panel sits over the bottom of the map. Lift both
        // clear of the collapsed handle.
        // Always show the compass, not MapLibre's default "only when rotated".
        // On a mountain a compass is a navigation instrument, not a hint that
        // the map is askew — and a walker who wants to know which way is north
        // should not have to rotate the map to find out.
        mapView.compassView.compassVisibility = .visible

        mapView.logoView.isHidden = false
        mapView.logoViewMargins = CGPoint(x: 8, y: 46)
        mapView.attributionButtonMargins = CGPoint(x: 8, y: 46)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false // we draw our own, from recorded fixes
        context.coordinator.mapView = mapView

        // Tapping a checkpoint is how its note gets read, and some of those
        // notes are the reason the checkpoint exists — a refuge that needs
        // booking, a footbridge that washes out. A pin you cannot open is
        // decoration.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        // Let the map keep its own gestures; ours only claims a hit on a pin.
        for existing in mapView.gestureRecognizers ?? [] where existing is UITapGestureRecognizer {
            tap.require(toFail: existing)
        }
        mapView.addGestureRecognizer(tap)
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updatePosition(position, mode: followMode)
        context.coordinator.applyFilter(kindFilter)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Where map packs live. Kept out of the trip document deliberately: tiles
    /// are large, replaceable, and must never travel through Drive sync.
    static var packsRoot: URL {
        URL.documentsDirectory.appendingPathComponent("packs", isDirectory: true)
    }

    /// The installed pack for this trip, if there is a usable one.
    static func installedPack(for package: TripPackage) -> OfflinePack? {
        OfflinePack.installed(in: packsRoot, tripId: package.tripId).first
    }

    private static func styleURL(for package: TripPackage) -> URL? {
        if let pack = installedPack(for: package), let style = try? pack.makeStyle() {
            return style
        }
        return URL(string: "https://demotiles.maplibre.org/style.json")
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var parent: RouteMapView
        weak var mapView: MLNMapView?
        private var didAddRoute = false
        /// Built once. `routeBearing` would otherwise rebuild an
        /// 8560-edge index on every fix, which is the one thing this view
        /// is careful never to do.
        private lazy var index = RouteIndex(segments: parent.package.plannedRoute.segments)

        private static let routeSourceID = "planned-route"
        private static let checkpointSourceID = "checkpoints"
        private static let positionSourceID = "position"

        init(parent: RouteMapView) {
            self.parent = parent
        }

        /// Show only the kinds asked for. One layer per kind makes this a
        /// visibility toggle rather than a rebuild — no source is touched, so
        /// filtering costs nothing while walking.
        func applyFilter(_ kinds: Set<CheckpointKind>) {
            guard let style = mapView?.style else { return }
            for kind in CheckpointKind.allCases {
                let show = kinds.isEmpty || kinds.contains(kind)
                style.layer(withIdentifier: "checkpoint-pins-\(kind.rawValue)")?.isVisible = show
                style.layer(withIdentifier: "checkpoint-labels-\(kind.rawValue)")?.isVisible = show
            }
        }

        // MARK: - Camera changes the walker made

        /// MapLibre reports *why* the camera moved, which is what lets a tap on
        /// the compass be told apart from our own recentring.
        func mapView(
            _ mapView: MLNMapView,
            regionDidChangeWith reason: MLNCameraChangeReason,
            animated: Bool
        ) {
            // Tapping the compass is an explicit "show me north". Staying in
            // course-up would turn the map back moments later, which reads as
            // the app arguing; and the old code was worse than either — it left
            // the map stuck north until the route happened to swing 20°.
            if reason.contains(.resetNorth), parent.followMode == .courseUp {
                lastCourse = nil
                parent.onFollowModeOverride?(.northUp)
                return
            }

            // Panning or rotating by hand means the walker is looking somewhere
            // else on purpose. Recentring on the next fix would snatch it back.
            let handMoved: MLNCameraChangeReason = [.gesturePan, .gestureRotate]
            if !reason.isDisjoint(with: handMoved), parent.followMode != .free {
                parent.onFollowModeOverride?(.free)
            }
        }

        // MARK: - Interaction

        /// Which layers a tap may hit, filled in as the pin layers are built.
        private var pinLayerIDs: Set<String> = []

        @MainActor @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let mapView, !pinLayerIDs.isEmpty else { return }
            let point = recognizer.location(in: mapView)
            // A generous box, not a point: these get tapped with cold hands,
            // through gloves, on a moving path.
            let box = CGRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)
            let hits = mapView.visibleFeatures(in: box, styleLayerIdentifiers: pinLayerIDs)

            guard let name = hits.compactMap({ $0.attribute(forKey: "name") as? String }).first,
                  let checkpoint = parent.package.checkpoints.first(where: { $0.displayName == name })
            else { return }
            parent.onSelectCheckpoint?(checkpoint, point)
        }

        // MARK: - Style

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            addRoute(to: style)
            addDirectionArrows(to: style)
            addCheckpoints(to: style)
            addPosition(to: style)
            zoomToRoute(mapView)
            didAddRoute = true
            updatePosition(parent.position, mode: parent.followMode)
        }

        private func addRoute(to style: MLNStyle) {
            let segments = parent.package.plannedRoute.segments
            // One polyline per segment: a gap between segments is a real break
            // in the route (a shuttle, a ferry), and joining them would draw a
            // line across country nobody walks.
            let polylines = segments.compactMap { segment -> MLNPolylineFeature? in
                let coordinates = segment.points.map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng)
                }
                guard coordinates.count >= 2 else { return nil }
                return MLNPolylineFeature(coordinates: coordinates, count: UInt(coordinates.count))
            }
            guard !polylines.isEmpty else { return }

            let source = MLNShapeSource(
                identifier: Self.routeSourceID,
                shapes: polylines,
                options: [.lineDistanceMetrics: true]
            )
            style.addSource(source)

            // Casing under the line so the route stays legible over dark
            // terrain and forest, which is most of an alpine basemap.
            let casing = MLNLineStyleLayer(identifier: "route-casing", source: source)
            casing.lineColor = NSExpression(forConstantValue: UIColor.white)
            casing.lineWidth = NSExpression(forConstantValue: 8)
            casing.lineCap = NSExpression(forConstantValue: "round")
            casing.lineJoin = NSExpression(forConstantValue: "round")
            casing.lineOpacity = NSExpression(forConstantValue: 0.9)
            style.addLayer(casing)

            let line = MLNLineStyleLayer(identifier: "route-line", source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor.systemIndigo)
            line.lineWidth = NSExpression(forConstantValue: 4.5)
            line.lineCap = NSExpression(forConstantValue: "round")
            line.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(line)
        }

        /// Direction-of-travel arrows repeated along the line.
        ///
        /// Every paper walking map and every hiking app marks this, because a
        /// route drawn as a bare line does not say which way round it goes —
        /// and on a loop like the Tour du Mont Blanc that is the difference
        /// between the plan and its reverse.
        private func addDirectionArrows(to style: MLNStyle) {
            guard let source = style.source(withIdentifier: Self.routeSourceID) else { return }
            style.setImage(Self.arrowImage(), forName: "route-arrow")

            let arrows = MLNSymbolStyleLayer(identifier: "route-arrows", source: source)
            arrows.iconImageName = NSExpression(forConstantValue: "route-arrow")
            arrows.symbolPlacement = NSExpression(forConstantValue: "line")
            // Far enough apart to read as direction rather than as decoration.
            arrows.symbolSpacing = NSExpression(forConstantValue: 90)
            arrows.iconAllowsOverlap = NSExpression(forConstantValue: false)
            arrows.iconRotationAlignment = NSExpression(forConstantValue: "map")
            arrows.iconScale = NSExpression(forConstantValue: 0.55)
            arrows.iconOpacity = NSExpression(forConstantValue: 0.95)
            style.addLayer(arrows)
        }

        private func addCheckpoints(to style: MLNStyle) {
            // One source and one layer per kind, every property constant.
            //
            // This is deliberately the dumbest form that works. Three cleverer
            // ones do not, all failing the same silent way — layer added,
            // source valid, nothing drawn, no error anywhere:
            //   * a Bool or Int anywhere in `feature.attributes`
            //   * `iconImageName` as a keyPath expression
            //   * `layer.predicate` filtering one source by attribute
            // Ten sources of a handful of points each cost nothing, and they
            // are the reason the trip's checkpoints are visible at all.
            let byKind = Dictionary(grouping: parent.package.checkpoints) { $0.checkpointKind }

            for (kind, checkpoints) in byKind {
                style.setImage(Self.pinImage(for: kind), forName: "cp-\(kind.rawValue)")

                let features = checkpoints.map { checkpoint -> MLNPointFeature in
                    let feature = MLNPointFeature()
                    feature.coordinate = CLLocationCoordinate2D(
                        latitude: checkpoint.lat, longitude: checkpoint.lng
                    )
                    feature.attributes = ["name": checkpoint.displayName]
                    return feature
                }
                guard !features.isEmpty else { continue }

                let source = MLNShapeSource(
                    identifier: "checkpoints-\(kind.rawValue)",
                    shape: MLNShapeCollectionFeature(shapes: features),
                    options: nil
                )
                style.addSource(source)

                let pins = MLNSymbolStyleLayer(
                    identifier: "checkpoint-pins-\(kind.rawValue)", source: source
                )
                pins.iconImageName = NSExpression(forConstantValue: "cp-\(kind.rawValue)")
                // Grows with zoom: at trip scale these are marks, and close in
                // they are things to read and press.
                pins.iconScale = NSExpression(
                    format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                    [
                        10: kind.isMajor ? 0.62 : 0.52,
                        14: kind.isMajor ? 0.85 : 0.72,
                        16: kind.isMajor ? 1.15 : 0.98
                    ]
                )
                // Sleeping places must never be dropped by collision: they are
                // what the day is planned around. The rest may yield.
                pins.iconAllowsOverlap = NSExpression(forConstantValue: kind.isMajor)
                style.addLayer(pins)
                pinLayerIDs.insert(pins.identifier)

                // Label only the places worth naming. Fifty-six labels on a
                // phone is noise; the icons already say what the rest are.
                guard kind.isMajor else { continue }
                let labels = MLNSymbolStyleLayer(
                    identifier: "checkpoint-labels-\(kind.rawValue)", source: source
                )
                labels.text = NSExpression(forKeyPath: "name")
                labels.textFontSize = NSExpression(forConstantValue: 11)
                // Refuge names run long ("Camping Les Rocailles, Champex-Lac").
                // Unconstrained they sprawl off the screen edge.
                labels.maximumTextWidth = NSExpression(forConstantValue: 8)
                labels.textColor = NSExpression(forConstantValue: UIColor.label)
                labels.textHaloColor = NSExpression(forConstantValue: UIColor.systemBackground)
                labels.textHaloWidth = NSExpression(forConstantValue: 1.5)
                labels.textAnchor = NSExpression(forConstantValue: "top")
                labels.textOffset = NSExpression(
                    forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.1))
                )
                style.addLayer(labels)
            }
        }

        // MARK: - Icon rendering

        /// A map pin for a checkpoint kind: coloured disc, white glyph, thin
        /// outline so it survives both pale scree and dark forest.
        private static func pinImage(for kind: CheckpointKind) -> UIImage {
            let size = CGSize(width: 44, height: 44)
            let colour = tint(for: kind)
            return UIGraphicsImageRenderer(size: size).image { context in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
                colour.setFill()
                UIColor.white.setStroke()
                let circle = UIBezierPath(ovalIn: rect)
                circle.lineWidth = 3
                circle.fill()
                circle.stroke()

                let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .bold)
                if let glyph = UIImage(systemName: kind.symbolName, withConfiguration: configuration)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                    let target = CGRect(
                        x: (size.width - glyph.size.width) / 2,
                        y: (size.height - glyph.size.height) / 2,
                        width: glyph.size.width,
                        height: glyph.size.height
                    )
                    glyph.draw(in: target)
                }
                _ = context
            }
        }

        private static func tint(for kind: CheckpointKind) -> UIColor {
            switch kind {
            case .overnight, .refuge: .systemOrange
            case .water: .systemTeal
            case .food, .resupply: .systemGreen
            case .hazard: .systemRed
            case .transport: .systemPurple
            case .pass: .systemBrown
            case .viewpoint: .systemBlue
            case .poi: .systemGray
            }
        }

        /// A chevron pointing along the line, drawn rather than shipped so it
        /// stays crisp at any scale and needs no asset catalogue.
        private static func arrowImage() -> UIImage {
            let size = CGSize(width: 24, height: 24)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 7, y: 5))
                path.addLine(to: CGPoint(x: 17, y: 12))
                path.addLine(to: CGPoint(x: 7, y: 19))
                path.lineWidth = 3.5
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                UIColor.white.setStroke()
                path.stroke()
                path.lineWidth = 2
                UIColor.systemIndigo.setStroke()
                path.stroke()
            }
        }

        /// The walker, as an arrow pointing the way the route runs.
        ///
        /// Replaces the dot whenever a bearing is known. Drawn large: this is
        /// the one thing on the map that answers "am I facing the right way",
        /// and it competes with a busy topo basemap for attention.
        /// Smallest angle between two bearings, in degrees.
        static func angleDelta(_ a: Double, _ b: Double) -> Double {
            var d = abs(a - b).truncatingRemainder(dividingBy: 360)
            if d > 180 { d = 360 - d }
            return d
        }

        private static func headingImage() -> UIImage {
            let size = CGSize(width: 56, height: 56)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 28, y: 6))       // tip
                path.addLine(to: CGPoint(x: 43, y: 44))   // right flank
                path.addLine(to: CGPoint(x: 28, y: 35))   // notch
                path.addLine(to: CGPoint(x: 13, y: 44))   // left flank
                path.close()

                UIColor.white.setStroke()
                path.lineWidth = 5
                path.lineJoinStyle = .round
                path.stroke()

                UIColor.systemBlue.setFill()
                path.fill()
            }
        }

        private func addPosition(to style: MLNStyle) {
            let source = MLNShapeSource(identifier: Self.positionSourceID, shape: nil)
            style.addSource(source)

            let halo = MLNCircleStyleLayer(identifier: "position-halo", source: source)
            halo.circleRadius = NSExpression(forConstantValue: 16)
            halo.circleColor = NSExpression(forConstantValue: UIColor.systemBlue)
            halo.circleOpacity = NSExpression(forConstantValue: 0.18)
            style.addLayer(halo)

            // Shown only when the route gives no bearing — see updatePosition.
            let dot = MLNCircleStyleLayer(identifier: "position-dot", source: source)
            dot.circleRadius = NSExpression(forConstantValue: 8)
            dot.circleColor = NSExpression(forConstantValue: UIColor.systemBlue)
            dot.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            dot.circleStrokeWidth = NSExpression(forConstantValue: 3)
            style.addLayer(dot)

            style.setImage(Self.headingImage(), forName: "position-heading")
            let heading = MLNSymbolStyleLayer(identifier: "position-heading", source: source)
            heading.iconImageName = NSExpression(forConstantValue: "position-heading")
            heading.iconRotation = NSExpression(forKeyPath: "bearing")
            heading.iconRotationAlignment = NSExpression(forConstantValue: "map")
            heading.iconAllowsOverlap = NSExpression(forConstantValue: true)
            heading.iconScale = NSExpression(forConstantValue: 0.92)
            style.addLayer(heading)
        }

        // MARK: - Updates

        /// The coordinate the map was last recentred on. SwiftUI calls
        /// `updateUIView` for *any* state change — opening a callout, switching
        /// a panel tab — and recentring on each one snatched the map back to
        /// the walker the moment they tapped a checkpoint to look at it.
        private var lastCentredOn: CLLocationCoordinate2D?

        /// The heading the camera was last turned to, so course-up only turns
        /// when the route has genuinely changed direction.
        private var lastCourse: Double?

        /// How far the route must swing before the map follows it.
        ///
        /// Measured on the real Tour du Mont Blanc: turning on every fix means
        /// 267 camera moves an hour, which is constant and nauseating to read.
        /// At 20° it is 47 an hour — about one every 75 seconds, which is what
        /// a walker actually experiences as "the map is pointing my way".
        private static let courseChangeThreshold = 20.0

        func updatePosition(_ coordinate: CLLocationCoordinate2D?, mode: FollowMode) {
            guard didAddRoute,
                  let style = mapView?.style,
                  let source = style.source(withIdentifier: Self.positionSourceID) as? MLNShapeSource
            else { return }

            guard let coordinate else {
                source.shape = nil
                return
            }
            let feature = MLNPointFeature()
            feature.coordinate = coordinate
            let bearing = parent.routeDistanceM.flatMap { bearingAlongRoute(at: $0) }
            feature.attributes = ["bearing": bearing ?? 0]
            source.shape = feature

            // One marker, not two. An arrow when the route says which way to
            // face, a plain dot when it does not — both at once read as clutter
            // and neither is clearer for it.
            style.layer(withIdentifier: "position-dot")?.isVisible = bearing == nil
            style.layer(withIdentifier: "position-heading")?.isVisible = bearing != nil

            guard mode != .free, let mapView else { return }
            let moved = lastCentredOn.map {
                abs($0.latitude - coordinate.latitude) > 1e-7
                    || abs($0.longitude - coordinate.longitude) > 1e-7
            } ?? true

            // Course-up turns only on a real change of direction. Switchbacks
            // make the bearing wander by a few degrees constantly, and a map
            // that answers every one of them is unreadable.
            var direction = mapView.direction
            var turning = false
            if mode == .courseUp, let bearing {
                let swing = lastCourse.map { Self.angleDelta($0, bearing) } ?? 360
                if swing >= Self.courseChangeThreshold {
                    direction = bearing
                    lastCourse = bearing
                    turning = true
                }
            } else if mode == .northUp, mapView.direction != 0 {
                direction = 0
                lastCourse = nil
                turning = true
            }

            guard moved || turning else { return }
            lastCentredOn = coordinate

            let camera = MLNMapCamera(
                lookingAtCenter: coordinate,
                altitude: mapView.camera.altitude,
                pitch: 0,
                heading: direction
            )
            mapView.setCamera(camera, withDuration: 0.45, animationTimingFunction: nil)
        }

        /// Heading taken from the line ahead, using the cached index.
        ///
        /// From the route rather than the compass: a phone in a hand swings
        /// about, while the path does not, and "which way does the trail go
        /// from here" is the question being asked.
        private func bearingAlongRoute(at routeDistanceM: Double) -> Double? {
            guard let here = index.position(atRouteDistance: routeDistanceM),
                  routeDistanceM + 1 < index.totalM,
                  let ahead = index.position(
                      atRouteDistance: min(index.totalM, routeDistanceM + 60)
                  )
            else { return nil }
            return TripPackage.bearing(
                fromLat: here.lat, fromLng: here.lng, toLat: ahead.lat, toLng: ahead.lng
            )
        }

        private func zoomToRoute(_ mapView: MLNMapView) {
            var minLat = Double.greatestFiniteMagnitude, maxLat = -Double.greatestFiniteMagnitude
            var minLng = Double.greatestFiniteMagnitude, maxLng = -Double.greatestFiniteMagnitude
            for segment in parent.package.plannedRoute.segments {
                for point in segment.points {
                    minLat = min(minLat, point.lat); maxLat = max(maxLat, point.lat)
                    minLng = min(minLng, point.lng); maxLng = max(maxLng, point.lng)
                }
            }
            guard minLat <= maxLat else { return }
            mapView.setVisibleCoordinateBounds(
                MLNCoordinateBounds(
                    sw: CLLocationCoordinate2D(latitude: minLat, longitude: minLng),
                    ne: CLLocationCoordinate2D(latitude: maxLat, longitude: maxLng)
                ),
                edgePadding: UIEdgeInsets(top: 40, left: 24, bottom: 40, right: 24),
                animated: false
            )
        }
    }
}
