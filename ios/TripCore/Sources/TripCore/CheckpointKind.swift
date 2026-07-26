import Foundation

/// The checkpoint vocabulary, mirroring `CHECKPOINT_KINDS` in trail.js.
///
/// These are the things a walker plans around: where to sleep, where the water
/// is, where the last shop before three days of nothing is. They are the reason
/// a trip is worth building in the planner at all, so the app has to show them
/// rather than only the next one.
public enum CheckpointKind: String, CaseIterable, Sendable {
    case overnight
    case refuge
    case food
    case water
    case resupply
    case transport
    case pass
    case viewpoint
    case hazard
    case poi

    public init(rawKind: String) {
        self = CheckpointKind(rawValue: rawKind) ?? .poi
    }

    public var label: String {
        switch self {
        case .overnight: "Overnight"
        case .refuge: "Refuge / hotel"
        case .food: "Food"
        case .water: "Water"
        case .resupply: "Resupply"
        case .transport: "Transport"
        case .pass: "Pass / summit"
        case .viewpoint: "Viewpoint"
        case .hazard: "Hazard"
        case .poi: "Landmark"
        }
    }

    /// SF Symbol name. Chosen to be legible at map-pin size rather than to be
    /// clever — these get read at a glance, in rain, at 12 pt.
    public var symbolName: String {
        switch self {
        case .overnight: "tent.fill"
        case .refuge: "house.fill"
        case .food: "fork.knife"
        case .water: "drop.fill"
        case .resupply: "cart.fill"
        case .transport: "tram.fill"
        case .pass: "mountain.2.fill"
        case .viewpoint: "camera.fill"
        case .hazard: "exclamationmark.triangle.fill"
        case .poi: "mappin"
        }
    }

    /// Whether this is a place the walk can stop for the night. These get more
    /// visual weight: they structure the days, and missing one costs a bed.
    public var isMajor: Bool {
        self == .overnight || self == .refuge
    }

    /// Ranks kinds by how much they matter when the map is too crowded to draw
    /// them all. Sleeping and hazards outrank a viewpoint.
    public var priority: Int {
        switch self {
        case .overnight: 0
        case .refuge: 1
        case .hazard: 2
        case .water: 3
        case .resupply: 4
        case .food: 5
        case .transport: 6
        case .pass: 7
        case .viewpoint: 8
        case .poi: 9
        }
    }
}

extension TripPackage.Checkpoint {
    public var checkpointKind: CheckpointKind { CheckpointKind(rawKind: kind) }

    /// What to show when the planner left the name blank.
    public var displayName: String {
        name.isEmpty ? checkpointKind.label : name
    }
}

extension TripPackage {
    /// The next checkpoints ahead of a position, nearest first.
    ///
    /// Plural on purpose. "Next: water in 2 km" answers one question; deciding
    /// whether to push on to the refuge or stop at the bivouac needs to see
    /// several stops and their spacing at once, which is exactly the judgement
    /// a walker makes late in the day.
    public func upcomingCheckpoints(after routeDistanceM: Double, limit: Int = 4) -> [Checkpoint] {
        checkpoints
            .filter { Double($0.routeDistanceM) > routeDistanceM }
            .prefix(limit)
            .map { $0 }
    }

    /// Bearing in degrees from true north for the direction of travel at a
    /// point on the route, or nil at the very end.
    ///
    /// Taken from the route rather than from the device's compass: a phone in a
    /// hand swings about, while the line ahead does not, and "which way does
    /// the path go from here" is the question being asked.
    public func routeBearing(at routeDistanceM: Double, lookAheadM: Double = 60) -> Double? {
        let index = RouteIndex(segments: plannedRoute.segments)
        guard let here = index.position(atRouteDistance: routeDistanceM),
              routeDistanceM + 1 < index.totalM,
              let ahead = index.position(
                  atRouteDistance: min(index.totalM, routeDistanceM + lookAheadM)
              )
        else { return nil }
        return Self.bearing(fromLat: here.lat, fromLng: here.lng, toLat: ahead.lat, toLng: ahead.lng)
    }

    public static func bearing(fromLat: Double, fromLng: Double, toLat: Double, toLng: Double) -> Double {
        let toRad = Double.pi / 180
        let dLng = (toLng - fromLng) * toRad
        let y = sin(dLng) * cos(toLat * toRad)
        let x = cos(fromLat * toRad) * sin(toLat * toRad)
            - sin(fromLat * toRad) * cos(toLat * toRad) * cos(dLng)
        let degrees = atan2(y, x) / toRad
        return degrees < 0 ? degrees + 360 : degrees
    }
}
