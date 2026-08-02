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
    /// The direction the walker is actually moving, when the receiver knows it.
    /// Falls back to the direction the route runs.
    var courseDegrees: Double?
    /// The point on the route the position matched to, when it is far enough
    /// away to be worth drawing the gap.
    var snappedTo: CLLocationCoordinate2D?
    /// Frame this stretch of the route instead of the whole thing.
    var focusRange: ClosedRange<Double>?
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
    /// The checkpoint whose callout is open, ringed on the map so it is
    /// obvious which pin the bubble belongs to.
    var highlighted: TripPackage.Checkpoint?
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
        context.coordinator.applyHighlight(highlighted)
        context.coordinator.applyFocus(focusRange)
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

        /// Ring the checkpoint whose callout is open. Without it the bubble
        /// floats with no visible tie to the pin it describes.
        private var lastFocus: ClosedRange<Double>?

        /// Frame a chosen day, once per change of choice.
        ///
        /// Not on every update: the walker is free to pan around inside the day
        /// they are reading, and a camera that snapped back on each redraw
        /// would make that impossible.
        func applyFocus(_ range: ClosedRange<Double>?) {
            guard didAddRoute, let mapView, range != lastFocus else { return }
            lastFocus = range
            paintDay(range, on: mapView.style)
            guard let range else {
                zoomToRoute(mapView)
                return
            }
            guard let bounds = RouteProfiles.profile(for: parent.package)
                .bounds(fromRouteM: range.lowerBound, toRouteM: range.upperBound)
            else { return }
            mapView.setVisibleCoordinateBounds(
                MLNCoordinateBounds(
                    sw: CLLocationCoordinate2D(latitude: bounds.minLat, longitude: bounds.minLng),
                    ne: CLLocationCoordinate2D(latitude: bounds.maxLat, longitude: bounds.maxLng)
                ),
                // The bottom inset clears the panel. Choosing a day is only
                // possible with the panel open, so framing the day into the
                // half of the map the panel is covering would hide the thing
                // just asked for.
                edgePadding: UIEdgeInsets(top: 56, left: 32, bottom: 270, right: 32),
                animated: true
            )
        }

        /// Lift the chosen day out of the trip, or put the trip back.
        private func paintDay(_ range: ClosedRange<Double>?, on style: MLNStyle?) {
            guard let style else { return }
            let dayLine = style.source(withIdentifier: "route-day") as? MLNShapeSource
            let daySpots = style.source(withIdentifier: "day-stops") as? MLNShapeSource

            guard let range else {
                dayLine?.shape = nil
                daySpots?.shape = nil
                setRouteDimmed(false, on: style)
                return
            }

            let points = RouteProfiles.profile(for: parent.package)
                .coordinates(fromRouteM: range.lowerBound, toRouteM: range.upperBound)
                .map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
            dayLine?.shape = points.count >= 2
                ? MLNPolylineFeature(coordinates: points, count: UInt(points.count))
                : nil

            let stops = parent.package.checkpoints
                .filter { range.contains(Double($0.routeDistanceM)) }
                .map { Self.point(at: $0) }
            daySpots?.shape = stops.isEmpty ? nil : MLNShapeCollectionFeature(shapes: stops)

            setRouteDimmed(true, on: style)
        }

        private func setRouteDimmed(_ dimmed: Bool, on style: MLNStyle) {
            let opacity = NSExpression(forConstantValue: dimmed ? 0.3 : 1.0)
            (style.layer(withIdentifier: "route-line") as? MLNLineStyleLayer)?
                .lineOpacity = opacity
            (style.layer(withIdentifier: "route-casing") as? MLNLineStyleLayer)?
                .lineOpacity = NSExpression(forConstantValue: dimmed ? 0.3 : 1.0)
            (style.layer(withIdentifier: "route-arrows") as? MLNSymbolStyleLayer)?
                .iconOpacity = NSExpression(forConstantValue: dimmed ? 0.3 : 0.95)
        }

        func applyHighlight(_ checkpoint: TripPackage.Checkpoint?) {
            guard let style = mapView?.style,
                  let source = style.source(withIdentifier: "checkpoint-highlight") as? MLNShapeSource
            else { return }
            guard let checkpoint else {
                source.shape = nil
                return
            }
            let feature = MLNPointFeature()
            feature.coordinate = CLLocationCoordinate2D(
                latitude: checkpoint.lat, longitude: checkpoint.lng
            )
            source.shape = feature
        }

        /// Show only the kinds asked for. One layer per kind makes this a
        /// visibility toggle rather than a rebuild — no source is touched, so
        /// filtering costs nothing while walking.
        func applyFilter(_ kinds: Set<CheckpointKind>) {
            guard let style = mapView?.style else { return }
            for kind in CheckpointKind.allCases {
                let show = kinds.isEmpty || kinds.contains(kind)
                style.layer(withIdentifier: "checkpoint-pins-\(kind.rawValue)")?.isVisible = show
            }
            #if DEBUG
            // Does hiding a layer free the symbols it was colliding with?
            if ProcessInfo.processInfo.arguments.contains("-uiTestCountVisible") {
                let view = mapView
                let names = kinds.isEmpty ? "all" : kinds.map(\.rawValue).joined(separator: ",")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    guard let view else { return }
                    let mapView = view
                    let ids = Set(CheckpointKind.allCases.map { "checkpoint-pins-\($0.rawValue)" })
                    let drawn = mapView.visibleFeatures(in: mapView.bounds, styleLayerIdentifiers: ids)
                    NSLog("ULPCOUNT filter=%@ drawn=%d", names, drawn.count)
                }
            }
            #endif

            // Names live in their own per-checkpoint layers, so they have to be
            // hidden alongside the pin they belong to.
            for checkpoint in parent.package.checkpoints {
                let show = kinds.isEmpty || kinds.contains(checkpoint.checkpointKind)
                style.layer(withIdentifier: "cp-label-\(checkpoint.id)")?.isVisible = show
            }
        }

        // MARK: - Camera changes the walker made

        /// While set, automatic recentring and rotation stand down.
        private var suspendedUntil: Date?
        private var resumeWork: DispatchWorkItem?

        /// How long a hand gesture holds the camera still.
        ///
        /// Long enough to look ahead at the next col and think about it, short
        /// enough that the map comes back on its own. The mode is a standing
        /// choice — panning to peek is not a decision to stop following, and
        /// making someone re-pick from three modes afterwards is absurd.
        private static let manualControlPause: TimeInterval = 15

        /// MapLibre reports *why* the camera moved, which is what lets the
        /// walker's own gestures be told apart from our recentring.
        func mapView(
            _ mapView: MLNMapView,
            regionDidChangeWith reason: MLNCameraChangeReason,
            animated: Bool
        ) {
            // A compass tap is a one-shot "point north". It fixes nothing and
            // switches nothing — so it suspends the camera like any other
            // gesture, and course-up resumes afterwards on its own.
            let byHand: MLNCameraChangeReason = [.gesturePan, .gestureRotate, .resetNorth]
            guard !reason.isDisjoint(with: byHand) else { return }

            if reason.contains(.resetNorth) {
                // Let the next course update apply from scratch rather than
                // measuring its swing against a heading the walker just undid.
                lastCourse = nil
            }
            suspend()
        }

        private func suspend() {
            suspendedUntil = Date().addingTimeInterval(Self.manualControlPause)
            resumeWork?.cancel()

            // Resume on a timer, not on the next fix: at a 15 m filter a fix can
            // be half a minute away, and the map should come back when the
            // walker stopped touching it, not when the GPS next speaks.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                suspendedUntil = nil
                updatePosition(parent.position, mode: parent.followMode)
            }
            resumeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.manualControlPause, execute: work)
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
            let daySpotSource = MLNShapeSource(identifier: "day-stops", shape: nil, options: nil)
            style.addSource(daySpotSource)
            let daySpots = MLNCircleStyleLayer(identifier: "day-stops", source: daySpotSource)
            // Wider than the largest pin at every zoom. At 15 pt the halo was
            // smaller than a major stop's icon and vanished behind the very
            // thing it was marking.
            daySpots.circleRadius = Self.zoomStops([10: 24, 14: 30, 16: 38])
            daySpots.circleColor = NSExpression(forConstantValue: UIColor.systemGreen)
            daySpots.circleOpacity = NSExpression(forConstantValue: 0.20)
            daySpots.circleStrokeColor = NSExpression(forConstantValue: UIColor.systemGreen)
            daySpots.circleStrokeWidth = NSExpression(forConstantValue: 2)
            style.addLayer(daySpots)

            let highlightSource = MLNShapeSource(identifier: "checkpoint-highlight", shape: nil)
            style.addSource(highlightSource)
            let ring = MLNCircleStyleLayer(identifier: "checkpoint-highlight", source: highlightSource)
            ring.circleRadius = NSExpression(forConstantValue: 22)
            ring.circleColor = NSExpression(forConstantValue: UIColor.brandOnMap)
            ring.circleOpacity = NSExpression(forConstantValue: 0.22)
            ring.circleStrokeColor = NSExpression(forConstantValue: UIColor.brandOnMap)
            ring.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
            style.addLayer(ring)

            addCheckpoints(to: style)
            addEndpoints(to: style)
            #if DEBUG
            observeDebugFocus()
            #endif
            // Added before the pins so both rings read as haloes behind the
            // artwork. They used to go on afterwards — the comment here has
            // always claimed otherwise — which drew a translucent green disc
            // over every icon it marked and left the orange campsites olive.
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
            casing.lineWidth = Self.zoomStops(
                [10: 7, 14: 11, 16: 16]
            )
            casing.lineCap = NSExpression(forConstantValue: "round")
            casing.lineJoin = NSExpression(forConstantValue: "round")
            casing.lineOpacity = NSExpression(forConstantValue: 0.9)
            style.addLayer(casing)

            let daySource = MLNShapeSource(identifier: "route-day", shape: nil, options: nil)
            style.addSource(daySource)

            let line = MLNLineStyleLayer(identifier: "route-line", source: source)
            line.lineColor = NSExpression(forConstantValue: UIColor.brandOnMap)
            line.lineWidth = Self.zoomStops(
                [10: 4, 14: 7, 16: 10.5]
            )
            line.lineCap = NSExpression(forConstantValue: "round")
            line.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(line)

            // The chosen day, drawn over the trip in a lighter green.
            //
            // Framing a day answered "where", and left "which part of this
            // line" to be worked out from the edges of the screen. Dimming the
            // rest and lifting the day says it outright, and keeps the trip
            // visible around it — a day with no context is a different map.
            let dayLine = MLNLineStyleLayer(identifier: "route-day", source: daySource)
            dayLine.lineColor = NSExpression(forConstantValue: UIColor.systemGreen)
            dayLine.lineWidth = Self.zoomStops([10: 5, 14: 8, 16: 12])
            dayLine.lineCap = NSExpression(forConstantValue: "round")
            dayLine.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(dayLine)
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
            arrows.symbolSpacing = NSExpression(forConstantValue: 100)
            arrows.iconAllowsOverlap = NSExpression(forConstantValue: false)
            arrows.iconRotationAlignment = NSExpression(forConstantValue: "map")
            arrows.iconScale = Self.zoomStops(
                [10: 0.5, 14: 0.8, 16: 1.1]
            )
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

            // Least important first, so the layers that matter are added last
            // and win collisions. Iterating the dictionary directly — which is
            // what this did — leaves the order undefined and free to change
            // between launches, so a hazard could lose its place to a nameless
            // landmark, and differently each time the app started.
            for kind in CheckpointKind.allCases.sorted(by: { $0.priority > $1.priority }) {
                guard let checkpoints = byKind[kind] else { continue }
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
                pins.iconScale = Self.zoomStops(
                    [
                        10: kind.isMajor ? 0.74 : 0.62,
                        14: kind.isMajor ? 1.0 : 0.86,
                        16: kind.isMajor ? 1.35 : 1.15
                    ]
                )
                // Collision box tight to the artwork. The default 2 pt margin
                // sits on top of the transparent border already inside each
                // icon, and between them they were reserving far more room than
                // the pin occupies — which is why over half the checkpoints
                // never reached the screen.
                pins.iconPadding = NSExpression(forConstantValue: 0)
                // Two rules, and which one applies depends on the zoom.
                //
                // Far out, a minor stop yields: fifty-six icons over 164 km is
                // a field of overlapping discs with the route lost underneath.
                // Close in it must not, because a name is a symbol too and it
                // competes with the very icon it belongs to — zooming in far
                // enough to read a landmark's name was exactly far enough to
                // lose the landmark.
                //
                // So minor kinds are drawn twice: this layer, which collides,
                // up to the zoom where names appear, and a second one below
                // that never yields from there on. Major stops and hazards
                // never yielded at any zoom and still do not.
                let alwaysShown = kind.isMajor || kind == .hazard
                pins.iconAllowsOverlap = NSExpression(forConstantValue: alwaysShown)
                if !alwaysShown { pins.maximumZoomLevel = Self.nameZoom }
                style.addLayer(pins)
                pinLayerIDs.insert(pins.identifier)

                // The close-in layer for minor kinds. A landmark swaps its grey
                // dot for a marker that hangs above the point rather than
                // sitting on it — a dot centred on a junction hides the
                // junction — and the rest simply keep their icon.
                if !alwaysShown {
                    let closeName = "cp-close-\(kind.rawValue)"
                    let image = kind == .poi
                        ? Self.markerImage(for: kind)
                        : Self.pinImage(for: kind)
                    style.setImage(image, forName: closeName)

                    let close = MLNSymbolStyleLayer(
                        identifier: "checkpoint-close-\(kind.rawValue)", source: source
                    )
                    close.iconImageName = NSExpression(forConstantValue: closeName)
                    close.iconScale = kind == .poi
                        ? Self.zoomStops([Double(Self.nameZoom): 0.75, 17: 1.1])
                        : Self.zoomStops([Double(Self.nameZoom): 0.8, 16: 1.15])
                    if kind == .poi {
                        // Anchored at the tip, which is the point of the shape.
                        close.iconAnchor = NSExpression(forConstantValue: "bottom")
                    }
                    close.iconPadding = NSExpression(forConstantValue: 0)
                    close.iconAllowsOverlap = NSExpression(forConstantValue: true)
                    close.minimumZoomLevel = Self.nameZoom
                    style.addLayer(close)
                    pinLayerIDs.insert(close.identifier)
                }

                // Label only the places worth naming. Fifty-six labels on a
                // phone is noise; the icons already say what the rest are.
                // Labels: one source and one layer per checkpoint, each with a
                // constant string.
                //
                // `text = NSExpression(forKeyPath: "name")` looks like the
                // obvious way and silently destroys the whole source — the pins
                // vanish with the labels, which is why no overnight stop or
                // refuge appeared on the map at all. That is the third property
                // to behave this way here, after `iconImageName` and
                // `predicate`: on this MapLibre build, a data-driven expression
                // over a shape source takes the source down with it, with no
                // error anywhere. Constants only.
                //
                // Every stop gets a name now, but not at every zoom: the
                // major ones from trip scale, the rest only once the map is
                // close enough that fifty-six names are not fifty-six pieces
                // of noise over the terrain.
                for checkpoint in checkpoints {
                    let labelFeature = MLNPointFeature()
                    labelFeature.coordinate = CLLocationCoordinate2D(
                        latitude: checkpoint.lat, longitude: checkpoint.lng
                    )
                    let labelSource = MLNShapeSource(
                        identifier: "cp-label-\(checkpoint.id)", shape: labelFeature, options: nil
                    )
                    style.addSource(labelSource)

                    let labels = MLNSymbolStyleLayer(
                        identifier: "cp-label-\(checkpoint.id)", source: labelSource
                    )
                    labels.text = NSExpression(forConstantValue: checkpoint.displayName)
                    // Naming the font is not optional. Left unset the layer
                    // asks for the SDK's default stack, the pack has no glyphs
                    // under that name, and the label draws nothing at all —
                    // which is why no stop on this map has ever shown a name.
                    labels.textFontNames = NSExpression(forConstantValue: [OfflineStyle.labelFont])
                    labels.textFontSize = NSExpression(forConstantValue: 11)
                    // Refuge names run long ("Camping Les Rocailles,
                    // Champex-Lac"); unconstrained they sprawl off the screen.
                    labels.maximumTextWidth = NSExpression(forConstantValue: 8)
                    labels.textColor = NSExpression(forConstantValue: UIColor.label)
                    labels.textHaloColor = NSExpression(forConstantValue: UIColor.systemBackground)
                    labels.textHaloWidth = NSExpression(forConstantValue: 1.5)
                    labels.textAnchor = NSExpression(forConstantValue: "top")
                    // Tight under the pin, touching it rather than clear of it.
                    // Held there deliberately: at trip scale the map is a field
                    // of pins, and a name floating a gap away stops belonging to
                    // any one of them. Overlapping the artwork slightly costs
                    // less than being unreadable about which stop it names.
                    labels.textOffset = NSExpression(
                        forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.2))
                    )
                    // Minor stops keep quiet until the map is close enough to
                    // read them. A landmark's name is worth nothing at trip
                    // scale and worth a lot standing at the junction.
                    if !kind.isMajor { labels.minimumZoomLevel = Self.nameZoom }
                    // And the name gives way to name-plus-note closer still.
                    if !checkpoint.note.isEmpty { labels.maximumZoomLevel = Self.noteZoom }
                    // Names may collide and drop; the pin beneath never does.
                    style.addLayer(labels)

                    // The note itself, once there is room for it. This is what
                    // the stop was made for — a booking, a water carry, a
                    // crossing that is out after rain — and it lives one tap
                    // away everywhere else in the app.
                    guard !checkpoint.note.isEmpty else { continue }
                    let noteSource = MLNShapeSource(
                        identifier: "cp-note-\(checkpoint.id)",
                        shape: Self.point(at: checkpoint), options: nil
                    )
                    style.addSource(noteSource)

                    let notes = MLNSymbolStyleLayer(
                        identifier: "cp-note-\(checkpoint.id)", source: noteSource
                    )
                    notes.text = NSExpression(
                        forConstantValue: "\(checkpoint.displayName)\n\(Self.gist(checkpoint.note))"
                    )
                    notes.textFontNames = NSExpression(forConstantValue: [OfflineStyle.labelFont])
                    notes.textFontSize = NSExpression(forConstantValue: 11)
                    notes.maximumTextWidth = NSExpression(forConstantValue: 11)
                    notes.textColor = NSExpression(forConstantValue: UIColor.label)
                    notes.textHaloColor = NSExpression(forConstantValue: UIColor.systemBackground)
                    notes.textHaloWidth = NSExpression(forConstantValue: 1.5)
                    notes.textAnchor = NSExpression(forConstantValue: "top")
                    notes.textOffset = NSExpression(
                        forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.2))
                    )
                    notes.minimumZoomLevel = Self.noteZoom
                    style.addLayer(notes)
                }
            }
        }

        /// Where the walk begins and ends.
        ///
        /// Absent until now, which left the two most basic questions about a
        /// route unanswered on the map: where do I start, and where does this
        /// finish. On a closed loop they are the same place, and drawing two
        /// markers on top of each other there would be worse than drawing none.
        /// A value that grows with zoom.
        ///
        /// Built with MapLibre's typed constructor rather than the format
        /// string every example uses. The format string works, but it asks
        /// Foundation's predicate parser to treat `mgl_interpolate:…` as a
        /// function, which it refuses on principle and logs a fault for —
        /// thirteen of them here, every time the style loads. Same expression,
        /// no parser, no faults.
        private static func zoomStops(_ stops: [Double: Double]) -> NSExpression {
            NSExpression(
                forMLNInterpolating: .zoomLevelVariable,
                curveType: .linear,
                parameters: nil,
                stops: NSExpression(forConstantValue: stops)
            )
        }

        private func addEndpoints(to style: MLNStyle) {
            let segments = parent.package.plannedRoute.segments
            guard let first = segments.first?.points.first,
                  let last = segments.last?.points.last else { return }

            let start = CLLocationCoordinate2D(latitude: first.lat, longitude: first.lng)
            let finish = CLLocationCoordinate2D(latitude: last.lat, longitude: last.lng)

            // Trust the planner's `loop` flag, but also catch a route that
            // closes on itself without being marked as one — a GPX exported
            // from a device rarely carries the intent, only the geometry.
            let apart = ActivityJournal.haversine(first.lat, first.lng, last.lat, last.lng)
            let isLoop = parent.package.trip.loop || apart < 120

            if isLoop {
                add(
                    endpoint: start,
                    name: endpointName(parent.package.trip.startName, fallback: "Start / Finish"),
                    symbol: "flag.checkered", colour: .label, id: "loop", to: style
                )
                return
            }
            // Deliberately not the brand green: these two badges are the one
            // place the phone is allowed to differ from the planner, because
            // start and finish need to be told apart at a glance and a route
            // already drawn in forest green cannot also mark its own start
            // with it.
            add(
                endpoint: start,
                name: endpointName(parent.package.trip.startName, fallback: "Start"),
                symbol: "flag.fill", colour: .systemGreen, id: "start", to: style
            )
            add(
                endpoint: finish,
                name: endpointName(parent.package.trip.finishName, fallback: "Finish"),
                symbol: "flag.checkered", colour: .label, id: "finish", to: style
            )
        }

        private func endpointName(_ given: String, fallback: String) -> String {
            given.isEmpty ? fallback : given
        }

        private func add(
            endpoint coordinate: CLLocationCoordinate2D,
            name: String,
            symbol: String,
            colour: UIColor,
            id: String,
            to style: MLNStyle
        ) {
            style.setImage(Self.endpointImage(symbol: symbol, colour: colour), forName: "endpoint-\(id)")

            // One source per layer, never one shared by two.
            //
            // The pin and its label started out over a single source and
            // *neither* drew — the same silent collapse this file has hit four
            // times before, with no error and a perfectly valid-looking style.
            // Whatever the underlying cause, the shape that works here is one
            // source, one layer.
            let source = MLNShapeSource(
                identifier: "endpoint-\(id)", shape: pointFeature(at: coordinate), options: nil
            )
            style.addSource(source)

            let pin = MLNSymbolStyleLayer(identifier: "endpoint-\(id)", source: source)
            pin.iconImageName = NSExpression(forConstantValue: "endpoint-\(id)")
            pin.iconScale = Self.zoomStops(
                [10: 0.8, 14: 1.05, 16: 1.4]
            )
            // The ends of the walk are never dropped for anything.
            pin.iconAllowsOverlap = NSExpression(forConstantValue: true)
            pin.iconPadding = NSExpression(forConstantValue: 0)
            style.addLayer(pin)

            // The name goes on its own layer over its own source.
            //
            // Setting `text` on the badge layer itself — a plain constant,
            // alongside `iconImageName` — makes the badge disappear. That is
            // the fifth property on this build to take a working layer down
            // without a word of explanation. Two layers cost nothing.
            let labelSource = MLNShapeSource(
                identifier: "endpoint-label-\(id)", shape: pointFeature(at: coordinate), options: nil
            )
            style.addSource(labelSource)

            let label = MLNSymbolStyleLayer(identifier: "endpoint-label-\(id)", source: labelSource)
            label.text = NSExpression(forConstantValue: name)
            label.textFontNames = NSExpression(forConstantValue: [OfflineStyle.labelFont])
            label.textFontSize = NSExpression(forConstantValue: 12)
            label.maximumTextWidth = NSExpression(forConstantValue: 8)
            label.textColor = NSExpression(forConstantValue: UIColor.label)
            label.textHaloColor = NSExpression(forConstantValue: UIColor.systemBackground)
            label.textHaloWidth = NSExpression(forConstantValue: 1.8)
            label.textAnchor = NSExpression(forConstantValue: "top")
            // As close as the badge allows. The badge is squarer and larger
            // than a checkpoint pin, so this cannot be as tight as a stop's
            // name, but it is the same intent: the label belongs to the mark
            // under it and should read that way.
            label.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 1.9)))
            style.addLayer(label)
        }

        #if DEBUG
        /// Move the camera from a screenshot script.
        ///
        /// Detail shots — icon size, line width, whether a label survives its
        /// collisions — can only be judged close in, and a headless run has no
        /// way to pinch. DEBUG-only, and driven by a notification so the shipped
        /// view keeps no test-shaped property.
        func observeDebugFocus() {
            NotificationCenter.default.addObserver(
                forName: Notification.Name("ULPDebugFocus"), object: nil, queue: .main
            ) { [weak self] note in
                guard let self, let mapView = self.mapView,
                      let info = note.userInfo as? [String: Double],
                      let lat = info["lat"], let lng = info["lng"], let zoom = info["zoom"]
                else { return }
                mapView.setCenter(
                    CLLocationCoordinate2D(latitude: lat, longitude: lng),
                    zoomLevel: zoom, animated: false
                )
            }
        }
        #endif

        private func pointFeature(at coordinate: CLLocationCoordinate2D) -> MLNPointFeature {
            let feature = MLNPointFeature()
            feature.coordinate = coordinate
            return feature
        }

        /// A squarer, flag-bearing marker so the ends of the walk do not read as
        /// just another checkpoint.
        private static func endpointImage(symbol: String, colour: UIColor) -> UIImage {
            let size = CGSize(width: 50, height: 50)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
                let badge = UIBezierPath(roundedRect: rect, cornerRadius: 11)
                colour.setFill()
                UIColor.systemBackground.setStroke()
                badge.lineWidth = 4
                badge.fill()
                badge.stroke()

                let configuration = UIImage.SymbolConfiguration(pointSize: 21, weight: .heavy)
                if let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                    .withTintColor(.systemBackground, renderingMode: .alwaysOriginal) {
                    glyph.draw(in: CGRect(
                        x: (size.width - glyph.size.width) / 2,
                        y: (size.height - glyph.size.height) / 2,
                        width: glyph.size.width,
                        height: glyph.size.height
                    ))
                }
            }
        }

        // MARK: - Icon rendering

        /// A map pin for a checkpoint kind: coloured disc, white glyph, thin
        /// outline so it survives both pale scree and dark forest.
        /// Glyphs are white except on the pale fills, where white on yellow is
        /// unreadable at pin size.
        private static func glyphColour(for kind: CheckpointKind) -> UIColor {
            kind == .resupply ? UIColor(white: 0.15, alpha: 1) : .white
        }

        /// Zoom levels at which the map starts saying more.
        ///
        /// Reasoned from how much ground the screen covers, then moved twice
        /// on what the phone actually looked like in the hand. The first pick
        /// was z14 for a name and z16 for a note; both were late enough that
        /// the map was already closer than anyone walking would hold it before
        /// anything appeared, and lowering them a notch and a half was still
        /// late. These are the numbers the device settled on.
        static let nameZoom: Float = 10.5
        static let noteZoom: Float = 13

        /// The first sentence of a note, short enough to sit on a map.
        ///
        /// Notes are Markdown and some run to paragraphs. What belongs here is
        /// the reminder, not the document — the rest is a tap away.
        static func gist(_ note: String) -> String {
            let flat = note
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard flat.count > 64 else { return flat }
            return flat.prefix(64).trimmingCharacters(in: .whitespaces) + "…"
        }

        static func point(at checkpoint: TripPackage.Checkpoint) -> MLNPointFeature {
            let feature = MLNPointFeature()
            feature.coordinate = CLLocationCoordinate2D(
                latitude: checkpoint.lat, longitude: checkpoint.lng
            )
            return feature
        }

        /// The landmark balloon's colour. Shared with nothing — a hazard is a
        /// red disc with a warning inside it, which is a different shape doing
        /// a different job.
        static let markerColour = UIColor.systemRed

        /// The map marker everyone already reads as "here".
        ///
        /// Two earlier attempts, both worse. A circle with a triangle stuck
        /// under it looked hand-cut, which it was. The system's `mappin` is a
        /// thin needle that all but disappears at map size and in grey.
        ///
        /// So the balloon is drawn properly: an arc over the top of the head,
        /// then a curve down each side into a single point. The curves are
        /// what make it a teardrop rather than a lollipop, and the point is
        /// the whole reason for the shape — it marks the coordinate without
        /// sitting on top of it.
        private static func markerImage(for kind: CheckpointKind) -> UIImage {
            let head = CGPoint(x: 15, y: 15)
            let radius: CGFloat = 11
            let tip = CGPoint(x: 15, y: 39)
            let size = CGSize(width: 30, height: 42)

            let path = UIBezierPath()
            // Over the top, from the lower left of the head round to the lower
            // right, leaving the bottom open for the taper.
            path.addArc(
                withCenter: head, radius: radius,
                startAngle: .pi * 0.82, endAngle: .pi * 0.18,
                clockwise: true
            )
            path.addQuadCurve(
                to: tip,
                controlPoint: CGPoint(x: head.x + radius * 0.72, y: head.y + radius * 1.35)
            )
            path.addQuadCurve(
                to: CGPoint(
                    x: head.x + radius * cos(.pi * 0.82),
                    y: head.y + radius * sin(.pi * 0.82)
                ),
                controlPoint: CGPoint(x: head.x - radius * 0.72, y: head.y + radius * 1.35)
            )
            path.close()

            return UIGraphicsImageRenderer(size: size).image { _ in
                UIColor.white.setStroke()
                // Red, not the kind's own grey. Grey is right for a dot at
                // trip scale, where a landmark is a reference mark among
                // fifty-six others; it is wrong for the one shape on the map
                // whose whole job is to say "this exact spot". The grey dot it
                // hands over from is unchanged.
                Self.markerColour.setFill()
                path.lineWidth = 3
                path.stroke()
                path.fill()
                // The hole, so the marker reads as a marker and not a blob.
                UIColor.white.setFill()
                UIBezierPath(
                    arcCenter: head, radius: radius * 0.42,
                    startAngle: 0, endAngle: .pi * 2, clockwise: true
                ).fill()
            }
        }

        private static func pinImage(for kind: CheckpointKind) -> UIImage {
            // A plain landmark is drawn as a small dot with no glyph. Twenty of
            // the fifty-six checkpoints on this trip are landmarks, and giving
            // them all a pin symbol made the map a field of identical grey
            // blobs that buried the water and the refuges among them. They are
            // reference marks; the things you plan around get the icons.
            if kind == .poi {
                let size = CGSize(width: 26, height: 26)
                return UIGraphicsImageRenderer(size: size).image { _ in
                    let rect = CGRect(origin: .zero, size: size).insetBy(dx: 5, dy: 5)
                    tint(for: kind).setFill()
                    UIColor.white.setStroke()
                    let dot = UIBezierPath(ovalIn: rect)
                    dot.lineWidth = 3
                    dot.fill()
                    dot.stroke()
                }
            }

            let size = CGSize(width: 46, height: 46)
            let colour = tint(for: kind)
            return UIGraphicsImageRenderer(size: size).image { _ in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
                colour.setFill()
                UIColor.white.setStroke()
                let circle = UIBezierPath(ovalIn: rect)
                // A thicker ring: these sit on woodland green and pale scree,
                // and the outline is what separates them from both.
                circle.lineWidth = 3.5
                circle.fill()
                circle.stroke()

                let configuration = UIImage.SymbolConfiguration(pointSize: 21, weight: .heavy)
                if let glyph = UIImage(systemName: kind.symbolName, withConfiguration: configuration)?
                    .withTintColor(glyphColour(for: kind), renderingMode: .alwaysOriginal) {
                    glyph.draw(in: CGRect(
                        x: (size.width - glyph.size.width) / 2,
                        y: (size.height - glyph.size.height) / 2,
                        width: glyph.size.width,
                        height: glyph.size.height
                    ))
                }
            }
        }

        /// Distinct hues, not a palette. Two kinds sharing a colour is two
        /// kinds a walker has to stop and think about, and "food" and
        /// "resupply" mean different things when the next shop is two days off.
        private static func tint(for kind: CheckpointKind) -> UIColor {
            switch kind {
            case .overnight: .systemOrange
            case .refuge: .systemPink
            case .food: .systemGreen
            case .resupply: .systemYellow
            case .water: .systemCyan
            case .transport: .systemPurple
            case .pass: .systemBrown
            case .viewpoint: .systemBlue
            case .hazard: .systemRed
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
                UIColor.brandOnMap.setStroke()
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
            // Under the marker, so the tether reads as a leader line rather
            // than something crossing it.
            let tetherSource = MLNShapeSource(identifier: "position-tether", shape: nil)
            style.addSource(tetherSource)
            let tether = MLNLineStyleLayer(identifier: "position-tether", source: tetherSource)
            tether.lineColor = NSExpression(forConstantValue: UIColor.systemBlue)
            tether.lineWidth = NSExpression(forConstantValue: 2)
            tether.lineOpacity = NSExpression(forConstantValue: 0.55)
            tether.lineDashPattern = NSExpression(forConstantValue: [2, 2])
            style.addLayer(tether)

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
            // The walker's own heading first. The route's direction is a
            // reasonable guess only while standing on the route; a step off it
            // and an arrow aligned to a line you are not on points at nothing.
            let bearing = parent.courseDegrees
                ?? parent.routeDistanceM.flatMap { bearingAlongRoute(at: $0) }
            feature.attributes = ["bearing": bearing ?? 0]
            source.shape = feature

            // One marker, not two. An arrow when the route says which way to
            // face, a plain dot when it does not — both at once read as clutter
            // and neither is clearer for it.
            style.layer(withIdentifier: "position-dot")?.isVisible = bearing == nil
            style.layer(withIdentifier: "position-heading")?.isVisible = bearing != nil

            // A tether to the matched point. Now that the marker sits where the
            // receiver says, "Off line 17 m" is a gap you can see; without the
            // line it is a marker floating in a field for no stated reason.
            if let tether = style.source(withIdentifier: "position-tether") as? MLNShapeSource {
                if let snapped = parent.snappedTo {
                    let points = [coordinate, snapped]
                    tether.shape = MLNPolylineFeature(
                        coordinates: points, count: UInt(points.count)
                    )
                } else {
                    tether.shape = nil
                }
            }

            guard mode != .free, let mapView else { return }
            // Hands off while the walker is looking somewhere on purpose.
            if let suspendedUntil, Date() < suspendedUntil { return }
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
