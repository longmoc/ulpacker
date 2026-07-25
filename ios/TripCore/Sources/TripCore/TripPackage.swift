import Foundation

/// The contract the web planner publishes and this app consumes.
///
/// Mirrors `src/lib/tripPackage.js`. Everything here exists on both sides, so
/// changing a field means changing it twice — the golden fixtures at
/// `fixtures/trips/` fail loudly when only one side moves.
///
/// Decoding is deliberately tolerant of *unknown* fields (Swift's synthesised
/// `Codable` ignores them) so a newer planner can add data without bricking an
/// older build, but strict about the ones it needs.
public struct TripPackage: Codable, Sendable, Equatable {
    public static let expectedFormat = "ulpacker-trip-package"
    public static let supportedSchemaVersion = 1
    public static let supportedHashAlgorithm = "fnv1a64"

    public let format: String
    public let schemaVersion: Int
    public let hashAlgorithm: String
    public let tripId: String
    public let revision: Int
    public let publishedAt: String
    public let trip: Trip
    public let plannedRoute: PlannedRoute
    public let checkpoints: [Checkpoint]
    public let itinerary: [Day]
    public let extraDays: [ExtraDay]
    public let navigationDefaults: NavigationDefaults
    public let contentHash: String

    public struct Trip: Codable, Sendable, Equatable {
        public let name: String
        public let description: String
        public let startName: String
        public let finishName: String
        public let loop: Bool
        public let startDayNumber: Int
    }

    public struct PlannedRoute: Codable, Sendable, Equatable {
        public let segments: [Segment]
        public let stats: Stats
    }

    /// A run of consecutive points. Two segments mean a real gap in the route
    /// (a shuttle, a ferry), not a rendering artefact — the planner already
    /// fuses ways that merely touch.
    public struct Segment: Codable, Sendable, Equatable {
        public let points: [TrackPoint]
    }

    public struct Stats: Codable, Sendable, Equatable {
        public let distanceM: Int
        public let ascentM: Int?
        public let descentM: Int?
        public let minEle: Int?
        public let maxEle: Int?
        public let elevationCoverage: Double
        public let pointCount: Int
        public let segmentCount: Int
    }

    /// Ordered by `routeDistanceM` — guaranteed by the builder, not by the
    /// caller, so the "next checkpoint" cursor can rely on it.
    public struct Checkpoint: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let note: String
        public let kind: String
        public let routeDistanceM: Int
        public let lat: Double
        public let lng: Double
        public let ele: Int?
    }

    public struct Day: Codable, Sendable, Equatable {
        public let index: Int
        public let startRouteM: Int
        public let endRouteM: Int
        public let distanceM: Int
        public let startBoundary: String
        public let startName: String
        public let endBoundary: String
        public let endName: String
        public let ascentM: Int?
        public let descentM: Int?
        public let note: String
    }

    /// A day with no geometry — travel, rest, shuttle. Shown in the list,
    /// never navigated.
    public struct ExtraDay: Codable, Sendable, Equatable {
        public let id: String
        public let before: String
        public let title: String
        public let note: String
    }

    public struct NavigationDefaults: Codable, Sendable, Equatable {
        public let offRouteEnterM: Int
        public let offRouteExitM: Int
    }
}

/// A point as it appears on the wire: `[lat, lng]` or `[lat, lng, ele]`.
///
/// JSON arrays rather than objects, because at 8.5k points per route the key
/// names would triple the file for no gain. The custom coding keeps that
/// compactness without leaking `[Double]` into the rest of the code.
public struct TrackPoint: Codable, Sendable, Equatable {
    public let lat: Double
    public let lng: Double
    public let ele: Int?

    public init(lat: Double, lng: Double, ele: Int?) {
        self.lat = lat
        self.lng = lng
        self.ele = ele
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        lat = try container.decode(Double.self)
        lng = try container.decode(Double.self)
        ele = container.isAtEnd ? nil : try container.decodeIfPresent(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(lat)
        try container.encode(lng)
        if let ele { try container.encode(ele) }
    }
}

// MARK: - Validation

public enum TripPackageError: Error, Equatable, CustomStringConvertible {
    case wrongFormat(String)
    case unsupportedSchemaVersion(Int)
    case unsupportedHashAlgorithm(String)
    case emptyRoute
    case coordinateOutOfRange(lat: Double, lng: Double)
    case contentHashMismatch(expected: String, actual: String)

    public var description: String {
        switch self {
        case .wrongFormat(let f):
            return "Not a trip package (format \"\(f)\")."
        case .unsupportedSchemaVersion(let v):
            return "Unsupported schemaVersion \(v); this build reads \(TripPackage.supportedSchemaVersion)."
        case .unsupportedHashAlgorithm(let a):
            return "Unsupported hashAlgorithm \"\(a)\"."
        case .emptyRoute:
            return "The package has no route to follow."
        case .coordinateOutOfRange(let lat, let lng):
            return "Coordinate out of range (\(lat), \(lng))."
        case .contentHashMismatch(let expected, let actual):
            return "contentHash mismatch (file says \(expected), content hashes to \(actual))."
        }
    }
}

extension TripPackage {
    /// Recompute the content hash of a package's raw bytes.
    ///
    /// Takes `Data` rather than a decoded value because the hash describes the
    /// file: fields this build doesn't model still have to count, or a newer
    /// planner's additions would silently stop being covered.
    public static func contentHash(of data: Data) throws -> String {
        // `publishedAt` changes on every export and `contentHash` cannot cover
        // itself, so both stay out — re-exporting an unchanged trip must yield
        // the same hash.
        let canonical = try CanonicalJSON.canonicalize(
            data: data,
            omittingTopLevelKeys: ["contentHash", "publishedAt"]
        )
        return FNV1a.hash64(canonical)
    }

    /// Decode and fully verify a package, including its content hash.
    ///
    /// Verification is not optional on this path: a package arrives by AirDrop
    /// or Drive and is then trusted for navigation for days, so a silently
    /// truncated file has to fail here rather than halfway up a mountain.
    public static func decode(from data: Data) throws -> TripPackage {
        let package = try JSONDecoder().decode(TripPackage.self, from: data)
        try package.validateStructure()
        let actual = try contentHash(of: data)
        guard actual == package.contentHash else {
            throw TripPackageError.contentHashMismatch(expected: package.contentHash, actual: actual)
        }
        return package
    }

    /// Structural checks only. The hash is verified in `decode(from:)`, which
    /// is the only place the original bytes are still available.
    public func validateStructure() throws {
        guard format == Self.expectedFormat else { throw TripPackageError.wrongFormat(format) }
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw TripPackageError.unsupportedSchemaVersion(schemaVersion)
        }
        guard hashAlgorithm == Self.supportedHashAlgorithm else {
            throw TripPackageError.unsupportedHashAlgorithm(hashAlgorithm)
        }
        guard !plannedRoute.segments.isEmpty,
              plannedRoute.segments.allSatisfy({ $0.points.count >= 2 }) else {
            throw TripPackageError.emptyRoute
        }
        for segment in plannedRoute.segments {
            for point in segment.points {
                guard (-90...90).contains(point.lat), (-180...180).contains(point.lng) else {
                    throw TripPackageError.coordinateOutOfRange(lat: point.lat, lng: point.lng)
                }
            }
        }
    }
}
