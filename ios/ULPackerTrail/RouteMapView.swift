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
    var followsPosition: Bool

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero)
        // A local pack wins whenever one is installed. The remote style is a
        // development convenience only — on a trail there is no signal, and a
        // map that quietly needs some is worse than no map at all.
        mapView.styleURL = Self.styleURL(for: package)
        mapView.logoView.isHidden = false
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false // we draw our own, from recorded fixes
        context.coordinator.mapView = mapView
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updatePosition(position, follow: followsPosition)
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

        private static let routeSourceID = "planned-route"
        private static let checkpointSourceID = "checkpoints"
        private static let positionSourceID = "position"

        init(parent: RouteMapView) {
            self.parent = parent
        }

        // MARK: - Style

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            addRoute(to: style)
            addCheckpoints(to: style)
            addPosition(to: style)
            zoomToRoute(mapView)
            didAddRoute = true
            updatePosition(parent.position, follow: parent.followsPosition)
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

        private func addCheckpoints(to style: MLNStyle) {
            let features = parent.package.checkpoints.map { checkpoint -> MLNPointFeature in
                let feature = MLNPointFeature()
                feature.coordinate = CLLocationCoordinate2D(
                    latitude: checkpoint.lat, longitude: checkpoint.lng
                )
                feature.attributes = [
                    "name": checkpoint.name,
                    "kind": checkpoint.kind,
                    // Overnight stops structure the walk; everything else is
                    // reference. Drawn differently so the important ones read
                    // at a glance on a small screen.
                    "overnight": checkpoint.kind == "overnight"
                ]
                return feature
            }
            guard !features.isEmpty else { return }

            let source = MLNShapeSource(identifier: Self.checkpointSourceID, features: features)
            style.addSource(source)

            let circles = MLNCircleStyleLayer(identifier: "checkpoint-dots", source: source)
            circles.circleRadius = NSExpression(
                forConditional: NSPredicate(format: "overnight == YES"),
                trueExpression: NSExpression(forConstantValue: 7),
                falseExpression: NSExpression(forConstantValue: 4)
            )
            circles.circleColor = NSExpression(
                forConditional: NSPredicate(format: "overnight == YES"),
                trueExpression: NSExpression(forConstantValue: UIColor.systemOrange),
                falseExpression: NSExpression(forConstantValue: UIColor.white)
            )
            circles.circleStrokeColor = NSExpression(forConstantValue: UIColor.darkGray)
            circles.circleStrokeWidth = NSExpression(forConstantValue: 1.5)
            style.addLayer(circles)

            let labels = MLNSymbolStyleLayer(identifier: "checkpoint-labels", source: source)
            labels.text = NSExpression(forKeyPath: "name")
            labels.textFontSize = NSExpression(forConstantValue: 11)
            // Refuge names run long ("Day 6 — Camping Les Rocailles,
            // Champex-Lac"). Unconstrained they sprawl across the map and off
            // the screen edge; wrapping at ~7 ems keeps them readable and lets
            // MapLibre's collision detection drop the ones that would overlap.
            labels.maximumTextWidth = NSExpression(forConstantValue: 7)
            labels.textColor = NSExpression(forConstantValue: UIColor.label)
            labels.textHaloColor = NSExpression(forConstantValue: UIColor.systemBackground)
            labels.textHaloWidth = NSExpression(forConstantValue: 1.5)
            labels.textAnchor = NSExpression(forConstantValue: "top")
            labels.textOffset = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: 0.8)))
            // Only label the overnight stops: 54 labels on a phone screen is
            // noise, and these are the ones a walker navigates between.
            labels.predicate = NSPredicate(format: "overnight == YES")
            style.addLayer(labels)
        }

        private func addPosition(to style: MLNStyle) {
            let source = MLNShapeSource(identifier: Self.positionSourceID, shape: nil)
            style.addSource(source)

            let halo = MLNCircleStyleLayer(identifier: "position-halo", source: source)
            halo.circleRadius = NSExpression(forConstantValue: 14)
            halo.circleColor = NSExpression(forConstantValue: UIColor.systemBlue)
            halo.circleOpacity = NSExpression(forConstantValue: 0.2)
            style.addLayer(halo)

            let dot = MLNCircleStyleLayer(identifier: "position-dot", source: source)
            dot.circleRadius = NSExpression(forConstantValue: 7)
            dot.circleColor = NSExpression(forConstantValue: UIColor.systemBlue)
            dot.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            dot.circleStrokeWidth = NSExpression(forConstantValue: 2.5)
            style.addLayer(dot)
        }

        // MARK: - Updates

        func updatePosition(_ coordinate: CLLocationCoordinate2D?, follow: Bool) {
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
            source.shape = feature

            if follow, let mapView {
                mapView.setCenter(coordinate, zoomLevel: max(mapView.zoomLevel, 13), animated: true)
            }
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
