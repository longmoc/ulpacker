import SwiftUI
import TripCore
import UIKit

/// Reads the battery, and nothing else.
///
/// The measurement has to be free. A nine-day walk cannot afford an instrument
/// that wakes the process to observe it, so this never schedules anything: it
/// answers when asked, the recorder asks on fixes that were arriving anyway,
/// and the sample rides to disk on the flush that was already happening.
///
/// Reading `batteryLevel` requires monitoring to be switched on, which is a
/// device-wide setting rather than a per-object one — hence the single shared
/// instance and the explicit enable/disable around a recording.
@MainActor
final class PowerMonitor {
    static let shared = PowerMonitor()

    /// Never sample faster than this. At a 15 m distance filter the recorder
    /// offers a reading roughly every 13 seconds; a nine-day trip at that rate
    /// would be a quarter of a million readings to describe a curve that moves
    /// in 1% steps.
    static let minimumIntervalS: TimeInterval = 60

    private var lastSampleAt: Date?
    private var enabled = false

    private init() {}

    func start() {
        guard !enabled else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        enabled = true
        lastSampleAt = nil
    }

    func stop() {
        guard enabled else { return }
        UIDevice.current.isBatteryMonitoringEnabled = false
        enabled = false
    }

    /// A reading, if one is due and the device has one to give.
    ///
    /// Nil on the simulator, which reports no level at all — the code path has
    /// to survive that, because the simulator is where everything else about
    /// this app gets exercised.
    func sample(at time: Date = Date(), force: Bool = false) -> Power.Sample? {
        guard enabled else { return nil }
        if !force, let lastSampleAt, time.timeIntervalSince(lastSampleAt) < Self.minimumIntervalS {
            return nil
        }

        let level = Double(UIDevice.current.batteryLevel)
        guard level >= 0 else { return nil }
        lastSampleAt = time

        let state = UIDevice.current.batteryState
        return Power.Sample(
            t: time,
            level: level,
            charging: state == .charging || state == .full,
            // The closest honest proxy for "the screen was on". The plan asks
            // for screen-on and screen-off to be told apart, and after the walk
            // there is no other way to separate them.
            foreground: UIApplication.shared.applicationState == .active,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: Self.name(ProcessInfo.processInfo.thermalState)
        )
    }

    private static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
