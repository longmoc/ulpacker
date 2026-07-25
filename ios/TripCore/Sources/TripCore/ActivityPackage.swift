import Foundation

/// What a recorded walk becomes: the other half of the contract.
///
/// Deliberately *not* the same shape as `TripPackage.plannedRoute`. A planned
/// route is geometry someone drew; an activity is evidence of what a device
/// observed, and evidence without time and accuracy cannot be judged later.
/// The web app's track sanitiser keeps only `[lat, lng, ele]`, which is why
/// reusing that schema here was rejected — see MOBILE_PLAN §2.1.
public struct ActivityPackage: Codable, Sendable, Equatable {
    public static let expectedFormat = "ulpacker-activity-package"
    public static let supportedSchemaVersion = 1

    public let format: String
    public let schemaVersion: Int
    public let activityId: String
    public let tripId: String
    public let tripRevision: Int
    /// Which itinerary day this session belongs to, when the walker picked one.
    public let stageId: String?
    public let status: Status
    public let startedAt: Date
    public let endedAt: Date?
    /// The location configuration actually in force, recorded so a field test
    /// can attribute a battery or accuracy result to a specific setup rather
    /// than to a remembered intention.
    public let nativeConfig: NativeConfig
    public let fixes: [Fix]
    public let stats: Stats
    public let diagnostics: Diagnostics

    public enum Status: String, Codable, Sendable {
        case recording
        case paused
        case finished
        /// Reconstructed from the journal after the app died mid-walk.
        case recovered
    }

    public struct NativeConfig: Codable, Sendable, Equatable {
        public let desiredAccuracy: String
        public let distanceFilterM: Double
        public let activityType: String
        public let pausesAutomatically: Bool
        public let allowsBackgroundUpdates: Bool

        public init(
            desiredAccuracy: String,
            distanceFilterM: Double,
            activityType: String,
            pausesAutomatically: Bool,
            allowsBackgroundUpdates: Bool
        ) {
            self.desiredAccuracy = desiredAccuracy
            self.distanceFilterM = distanceFilterM
            self.activityType = activityType
            self.pausesAutomatically = pausesAutomatically
            self.allowsBackgroundUpdates = allowsBackgroundUpdates
        }
    }

    /// One observation. `seq` is assigned by the recorder, never by the OS, so
    /// gaps in the journal are detectable after a crash.
    public struct Fix: Codable, Sendable, Equatable {
        public let seq: Int
        public let t: Date
        public let lat: Double
        public let lng: Double
        /// Horizontal accuracy in metres. Negative means the OS considered the
        /// fix invalid; such fixes are journalled but never drive decisions.
        public let hAcc: Double
        public let alt: Double?
        public let vAcc: Double?
        public let speed: Double?
        public let bearing: Double?
        public let flags: [String]

        public init(
            seq: Int,
            t: Date,
            lat: Double,
            lng: Double,
            hAcc: Double,
            alt: Double? = nil,
            vAcc: Double? = nil,
            speed: Double? = nil,
            bearing: Double? = nil,
            flags: [String] = []
        ) {
            self.seq = seq
            self.t = t
            self.lat = lat
            self.lng = lng
            self.hAcc = hAcc
            self.alt = alt
            self.vAcc = vAcc
            self.speed = speed
            self.bearing = bearing
            self.flags = flags
        }

        /// Whether this fix is trustworthy enough to move the position cursor
        /// or raise an off-route alert. Bad fixes still get recorded — throwing
        /// them away would hide exactly the conditions worth debugging.
        public func isUsable(maxAccuracyM: Double) -> Bool {
            hAcc >= 0 && hAcc <= maxAccuracyM
        }
    }

    public struct Stats: Codable, Sendable, Equatable {
        public let fixCount: Int
        public let usableFixCount: Int
        public let distanceM: Int
        public let durationS: Int

        public init(fixCount: Int, usableFixCount: Int, distanceM: Int, durationS: Int) {
            self.fixCount = fixCount
            self.usableFixCount = usableFixCount
            self.distanceM = distanceM
            self.durationS = durationS
        }
    }

    /// Everything a field test needs to explain a bad result. Percentiles rather
    /// than averages, because a mean inter-fix gap hides the ten-minute hole
    /// that actually ruined the track.
    public struct Diagnostics: Codable, Sendable, Equatable {
        public let maxGapS: Int
        public let maxGapM: Int
        public let rejectedFixCount: Int
        public let recoveredFromCrash: Bool

        public init(maxGapS: Int, maxGapM: Int, rejectedFixCount: Int, recoveredFromCrash: Bool) {
            self.maxGapS = maxGapS
            self.maxGapM = maxGapM
            self.rejectedFixCount = rejectedFixCount
            self.recoveredFromCrash = recoveredFromCrash
        }
    }
}
