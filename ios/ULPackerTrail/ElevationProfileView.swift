import SwiftUI
import TripCore

/// Which end of a measurement a drag is moving.
enum ProfilePoint {
    case a
    case b
}

/// The route's elevation profile, with the walker's position on it.
///
/// On a mountain route this is not decoration: 4 km with 900 m of climb is a
/// different afternoon from 4 km along a valley, and the profile is the only
/// thing that says which one is ahead. Drawn from the planned route's own
/// points, so it needs no network and no service.
struct ElevationProfileView: View {
    let package: TripPackage
    /// Where the walker is along the route, if recording.
    var routeDistanceM: Double?
    /// Checkpoints are marked so climbs can be read against the stops.
    var showsCheckpoints = true
    /// The two points a finger can put on the chart, in route metres.
    ///
    /// One answers "what is here". Two answer "what is between here and
    /// there", which is the question behind every decision on a walk: whether
    /// to push on to the next col before dark, whether the climb after lunch is
    /// the one that hurts.
    @Binding var pointA: Double?
    @Binding var pointB: Double?
    /// Which of the two the next drag moves.
    @Binding var moving: ProfilePoint
    /// Draw only this stretch of the route.
    ///
    /// The whole trip on a phone gives a walking day about forty points of
    /// width — three millimetres for twenty-five kilometres and 1,900 m of
    /// climb. The numbers were always there; the shape was not, and the shape
    /// is what says "one long col" rather than "three climbs".
    var range: ClosedRange<Double>?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let samples = Self.samples(for: package, in: range)

            if samples.count < 2 {
                Text("No elevation data in this route.")
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let bounds = Self.bounds(samples, range: range)
                ZStack(alignment: .topLeading) {
                    profileShape(samples: samples, bounds: bounds, size: size)
                    if showsCheckpoints {
                        checkpointMarks(bounds: bounds, size: size)
                    }
                    if let routeDistanceM {
                        positionMark(at: routeDistanceM, bounds: bounds, size: size)
                    }
                    if let pointA, let pointB {
                        span(from: pointA, to: pointB, bounds: bounds, size: size)
                    }
                    if let pointA {
                        scrubMark(at: pointA, bounds: bounds, size: size, label: "A")
                    }
                    if let pointB {
                        scrubMark(at: pointB, bounds: bounds, size: size, label: "B")
                    }
                    axisLabels(bounds: bounds, size: size)
                }
                .contentShape(Rectangle())
                // Touch anywhere on the chart to read that point, and slide
                // along it to read the climb ahead without leaving the map.
                // minimumDistance 0 so a tap works as well as a drag.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let fraction = min(max(0, value.location.x / size.width), 1)
                            let routeM = bounds.startM + Double(fraction) * bounds.spanM
                            switch moving {
                            case .a: pointA = routeM
                            case .b: pointB = routeM
                            }
                        }
                )
            }
        }
    }

    // MARK: - Drawing

    private func profileShape(
        samples: [(routeM: Double, ele: Double)],
        bounds: Bounds,
        size: CGSize
    ) -> some View {
        let points = samples.map { sample in
            CGPoint(
                x: bounds.x(sample.routeM, in: size),
                y: bounds.y(sample.ele, in: size)
            )
        }
        return ZStack {
            // Filled area first: it reads as terrain rather than as a chart.
            Path { path in
                guard let first = points.first, let last = points.last else { return }
                path.move(to: CGPoint(x: first.x, y: size.height))
                for point in points { path.addLine(to: point) }
                path.addLine(to: CGPoint(x: last.x, y: size.height))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [.brand.opacity(0.28), .brand.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom
                )
            )

            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(Color.brand, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        }
    }

    private func checkpointMarks(bounds: Bounds, size: CGSize) -> some View {
        let visible = package.checkpoints.filter {
            $0.ele != nil && (range?.contains(Double($0.routeDistanceM)) ?? true)
        }
        return ForEach(visible, id: \.id) { checkpoint in
            let x = bounds.x(Double(checkpoint.routeDistanceM), in: size)
            let y = bounds.y(Double(checkpoint.ele ?? 0), in: size)
            Circle()
                .fill(Self.tint(for: checkpoint.checkpointKind))
                .frame(width: checkpoint.checkpointKind.isMajor ? 7 : 4.5)
                .overlay(Circle().stroke(.white, lineWidth: 1))
                .position(x: x, y: y)
        }
    }

    private func positionMark(at routeM: Double, bounds: Bounds, size: CGSize) -> some View {
        let x = bounds.x(routeM, in: size)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.blue.opacity(0.75))
                .frame(width: 1.5, height: size.height)
                .position(x: x, y: size.height / 2)
            Circle()
                .fill(Color.blue)
                .frame(width: 9)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .position(x: x, y: bounds.y(elevation(at: routeM), in: size))
        }
    }

    /// A point being read, marked so the numbers below have somewhere to point.
    private func scrubMark(
        at routeM: Double, bounds: Bounds, size: CGSize, label: String
    ) -> some View {
        let x = bounds.x(routeM, in: size)
        return ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.brand)
                .frame(width: 1.5, height: size.height)
                .position(x: x, y: size.height / 2)
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(3)
                .background(Circle().fill(Color.brand))
                .position(x: x, y: bounds.y(elevation(at: routeM), in: size))
        }
    }

    /// The stretch between the two points, so the measurement is visible on the
    /// chart and not only in the figures underneath it.
    private func span(
        from: Double, to: Double, bounds: Bounds, size: CGSize
    ) -> some View {
        let left = min(bounds.x(from, in: size), bounds.x(to, in: size))
        let right = max(bounds.x(from, in: size), bounds.x(to, in: size))
        return Rectangle()
            .fill(Color.brand.opacity(0.14))
            .frame(width: max(0, right - left), height: size.height)
            .position(x: (left + right) / 2, y: size.height / 2)
    }

    private func axisLabels(bounds: Bounds, size: CGSize) -> some View {
        VStack {
            HStack {
                Text("\(Int(bounds.maxEle)) m")
                Spacer()
                Text(String(format: "%.1f km", bounds.spanM / 1000))
            }
            Spacer()
            HStack {
                Text("\(Int(bounds.minEle)) m")
                Spacer()
            }
        }
        .font(.caption2)
        .foregroundStyle(Color.subtle)
        .padding(.horizontal, 2)
    }

    // MARK: - Geometry

    private func elevation(at routeM: Double) -> Double {
        let samples = Self.samples(for: package)
        guard let nearest = samples.min(by: { abs($0.routeM - routeM) < abs($1.routeM - routeM) })
        else { return 0 }
        return nearest.ele
    }

    struct Bounds {
        let startM: Double
        let endM: Double
        let minEle: Double
        let maxEle: Double

        var spanM: Double { endM - startM }

        func x(_ routeM: Double, in size: CGSize) -> CGFloat {
            guard spanM > 0 else { return 0 }
            return CGFloat((routeM - startM) / spanM) * size.width
        }

        func y(_ ele: Double, in size: CGSize) -> CGFloat {
            let span = max(1, maxEle - minEle)
            // Leave headroom so the peak is not clipped against the top edge.
            let usable = size.height - 14
            return 8 + usable * CGFloat(1 - (ele - minEle) / span)
        }
    }

    private static func bounds(
        _ samples: [(routeM: Double, ele: Double)], range: ClosedRange<Double>?
    ) -> Bounds {
        let elevations = samples.map(\.ele)
        return Bounds(
            // The chosen range, not the sampled extent: a day whose first
            // sample lands 30 m in should still start at its own kilometre
            // zero, or the checkpoint marks drift against the line.
            startM: range?.lowerBound ?? 0,
            endM: range?.upperBound ?? (samples.last?.routeM ?? 1),
            minEle: elevations.min() ?? 0,
            maxEle: elevations.max() ?? 1
        )
    }

    /// Decimated profile samples.
    ///
    /// 8561 points is far more than a 390-point-wide phone screen can show, and
    /// drawing them all would rebuild a path of thousands of segments on every
    /// position update. Cached per trip so the cost is paid once.
    static func samples(
        for package: TripPackage, in range: ClosedRange<Double>? = nil
    ) -> [(routeM: Double, ele: Double)] {
        // Decimated per range, not once for the trip: 400 samples spread over
        // 164 km leave a single day with about forty, which is a sketch of a
        // day rather than a profile of one.
        let key = range.map { "\(package.tripId)#\(Int($0.lowerBound))-\(Int($0.upperBound))" }
            ?? package.tripId
        if let cached = cache[key] { return cached }

        var result: [(routeM: Double, ele: Double)] = []
        var routeM = 0.0
        var previous: TrackPoint?
        var raw: [(Double, Double)] = []

        for segment in package.plannedRoute.segments {
            for point in segment.points {
                if let previous {
                    routeM += ActivityJournal.haversine(
                        previous.lat, previous.lng, point.lat, point.lng
                    )
                }
                previous = point
                guard range?.contains(routeM) ?? true else { continue }
                if let ele = point.ele { raw.append((routeM, Double(ele))) }
            }
        }
        guard !raw.isEmpty else { return [] }

        // ~400 samples: one per pixel of a phone-width chart.
        let stride = max(1, raw.count / 400)
        for index in Swift.stride(from: 0, to: raw.count, by: stride) {
            result.append((routeM: raw[index].0, ele: raw[index].1))
        }
        if let last = raw.last { result.append((routeM: last.0, ele: last.1)) }

        cache[key] = result
        return result
    }

    private nonisolated(unsafe) static var cache: [String: [(routeM: Double, ele: Double)]] = [:]

    /// Must match `RouteMapView.tint(for:)` — a stop cannot be one colour on
    /// the map and another in the list beneath it.
    static func tint(for kind: CheckpointKind) -> Color {
        switch kind {
        case .overnight: .orange
        case .refuge: .pink
        case .food: .green
        case .resupply: .yellow
        case .water: .cyan
        case .transport: .purple
        case .pass: .brown
        case .viewpoint: .blue
        case .hazard: .red
        case .poi: .gray
        }
    }
}
