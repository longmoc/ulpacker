import Foundation

/// What the walk cost the battery.
///
/// Battery is the level-0 priority for this app and it cannot be computed from
/// first principles. Nobody can say what Core Location costs on a given phone,
/// at a given temperature, on a given iOS build, from a datasheet — the only
/// honest number is a measured one. So the app measures itself: it samples the
/// battery while recording and folds the result into the activity, where it
/// sits next to the `nativeConfig` that produced it.
///
/// That pairing is the point. MOBILE_PLAN §6.2 asks for one variable changed
/// per run, judged against the device's own baseline; a rate with no record of
/// the configuration that produced it cannot answer anything, and a
/// configuration with no rate is an intention.
public enum Power {
    /// One reading. Sampled on the journal's existing flush schedule rather
    /// than a timer of its own — a walk that must last nine days cannot afford
    /// a measurement that wakes the process to take itself.
    public struct Sample: Codable, Sendable, Equatable {
        public let t: Date
        /// 0…1, as iOS reports it. Devices quantise this — historically to 5% —
        /// which is why a rate is only computed over long enough a span.
        public let level: Double
        /// Plugged in, by any means. Drain measured across a charging period is
        /// meaningless and is discarded rather than averaged in.
        public let charging: Bool
        /// The app was frontmost, which is the closest thing available to
        /// "screen was on". The plan asks for screen-on and screen-off to be
        /// measured separately; without this flag they cannot be separated
        /// after the fact.
        public let foreground: Bool
        public let lowPowerMode: Bool
        /// `ProcessInfo.ThermalState` as a string. A phone in a warm pocket
        /// throttles, and a drain figure with no thermal context invites the
        /// wrong conclusion.
        public let thermal: String
        /// This sample opens a new recording segment after a pause. The
        /// interval leading up to it — the paused stretch, which can be a lunch
        /// or a whole night — is not recording and must not be charged to it.
        /// Optional so journals written before this existed decode as `nil`,
        /// i.e. not a boundary.
        public let boundary: Bool?

        public init(
            t: Date,
            level: Double,
            charging: Bool,
            foreground: Bool,
            lowPowerMode: Bool,
            thermal: String,
            boundary: Bool? = nil
        ) {
            self.t = t
            self.level = level
            self.charging = charging
            self.foreground = foreground
            self.lowPowerMode = lowPowerMode
            self.thermal = thermal
            self.boundary = boundary
        }
    }

    /// The drain, derived from the samples.
    public struct Report: Codable, Sendable, Equatable {
        public let sampleCount: Int
        /// Seconds spent on battery, charging periods excluded.
        public let dischargeS: Int
        /// Percentage points lost over those seconds.
        public let drainedPercent: Double
        /// The headline figure, or nil when there is not enough to say.
        public let percentPerHour: Double?
        /// The same split by whether the app was frontmost. A walker holding
        /// the phone to read the map is a different power story from one with
        /// it in a pocket, and on a nine-day trip almost all of it is pocket.
        public let foregroundS: Int
        public let foregroundPercentPerHour: Double?
        public let backgroundS: Int
        public let backgroundPercentPerHour: Double?
        public let lowPowerModeSeen: Bool
        public let maxThermal: String

        /// Whether the headline rate is worth quoting.
        ///
        /// A phone that reports its battery in 5% steps will show a 5-point
        /// drop three minutes into a walk, and 5 points over three minutes is
        /// 100%/hour. The guard is not pedantry: an unreliable first number
        /// would be the one that gets remembered.
        public var isReliable: Bool {
            dischargeS >= Power.minimumReliableS && drainedPercent >= Power.minimumReliableDrop
        }

        /// Whether the background rate is worth *forecasting from*, as opposed to
        /// merely being a number. A pocket stretch can pass the half-hour mark
        /// with the level not yet ticking down a quantum; the resulting "0 %/h"
        /// clears the time bar but measures nothing, and the forecast used to
        /// prefer it for exactly that reason. It needs the drop too — the same
        /// two-conditions test as the headline, applied to the bucket's own span.
        public var backgroundReliable: Bool {
            guard let rate = backgroundPercentPerHour else { return false }
            let drained = rate * Double(backgroundS) / 3600
            return backgroundS >= Power.minimumReliableS && drained >= Power.minimumReliableDrop
        }

        public var foregroundReliable: Bool {
            guard let rate = foregroundPercentPerHour else { return false }
            let drained = rate * Double(foregroundS) / 3600
            return foregroundS >= Power.minimumReliableS && drained >= Power.minimumReliableDrop
        }

        public init(
            sampleCount: Int,
            dischargeS: Int,
            drainedPercent: Double,
            percentPerHour: Double?,
            foregroundS: Int,
            foregroundPercentPerHour: Double?,
            backgroundS: Int,
            backgroundPercentPerHour: Double?,
            lowPowerModeSeen: Bool,
            maxThermal: String
        ) {
            self.sampleCount = sampleCount
            self.dischargeS = dischargeS
            self.drainedPercent = drainedPercent
            self.percentPerHour = percentPerHour
            self.foregroundS = foregroundS
            self.foregroundPercentPerHour = foregroundPercentPerHour
            self.backgroundS = backgroundS
            self.backgroundPercentPerHour = backgroundPercentPerHour
            self.lowPowerModeSeen = lowPowerModeSeen
            self.maxThermal = maxThermal
        }
    }

    /// Half an hour, and two percentage points, before a rate is quotable.
    public static let minimumReliableS = 1_800
    public static let minimumReliableDrop = 2.0

    // MARK: - Derivation

    /// Fold samples into a report.
    ///
    /// Works pairwise, so a session that was interrupted, backgrounded, or
    /// plugged in halfway contributes only the stretches that mean something.
    public static func report(for samples: [Sample]) -> Report? {
        guard samples.count >= 2 else { return nil }
        let ordered = samples.sorted { $0.t < $1.t }

        var dischargeS = 0.0
        var drained = 0.0
        var foregroundS = 0.0
        var foregroundDrained = 0.0
        var backgroundS = 0.0
        var backgroundDrained = 0.0

        for (previous, next) in zip(ordered, ordered.dropFirst()) {
            let seconds = next.t.timeIntervalSince(previous.t)
            guard seconds > 0 else { continue }
            // Either end plugged in and the pair says nothing about drain.
            guard !previous.charging, !next.charging else { continue }
            // `next` opens a fresh segment after a pause, so this pair spans the
            // paused stretch — a lunch, an overnight — which is not recording
            // and would otherwise dilute or inflate the rate depending on what
            // the phone did while set down. Skip it.
            guard next.boundary != true else { continue }

            // Clamped at zero: a level that rises on battery is the reporting
            // granularity moving, not energy appearing.
            let drop = max(0, (previous.level - next.level) * 100)
            dischargeS += seconds
            drained += drop

            // Only pairs that stayed on one side are attributed; a pair that
            // straddles the screen going off belongs to neither.
            if previous.foreground, next.foreground {
                foregroundS += seconds
                foregroundDrained += drop
            } else if !previous.foreground, !next.foreground {
                backgroundS += seconds
                backgroundDrained += drop
            }
        }

        return Report(
            sampleCount: ordered.count,
            dischargeS: Int(dischargeS.rounded()),
            drainedPercent: (drained * 100).rounded() / 100,
            percentPerHour: rate(drained, over: dischargeS),
            foregroundS: Int(foregroundS.rounded()),
            foregroundPercentPerHour: rate(foregroundDrained, over: foregroundS),
            backgroundS: Int(backgroundS.rounded()),
            backgroundPercentPerHour: rate(backgroundDrained, over: backgroundS),
            lowPowerModeSeen: ordered.contains(where: \.lowPowerMode),
            maxThermal: ordered.map(\.thermal).max(by: { severity($0) < severity($1) }) ?? "nominal"
        )
    }

    private static func rate(_ drained: Double, over seconds: Double) -> Double? {
        guard seconds >= Double(minimumReliableS) else { return nil }
        let value = drained / (seconds / 3600)
        return (value * 100).rounded() / 100
    }

    private static func severity(_ thermal: String) -> Int {
        switch thermal {
        case "critical": 3
        case "serious": 2
        case "fair": 1
        default: 0
        }
    }
}
