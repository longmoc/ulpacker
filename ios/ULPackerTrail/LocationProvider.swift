import CoreLocation
import Foundation
import Observation

/// The only part of recording that needs a real phone.
///
/// Everything downstream of `onFix` lives in TripCore and is tested on a Mac;
/// this wrapper exists to be thin enough that there is little here left to be
/// wrong. It is also the seam the plan reserves for a hand-written replacement
/// if the stock configuration turns out not to hold up in the field.
///
/// The configuration is deliberate rather than default, because the plan review
/// singled it out: a distance filter alone says nothing about what the GPS
/// radio is doing. All four settings below move together.
@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum Authorization: Equatable {
        case notDetermined
        case denied
        /// Enough to record with the screen off, given the background mode.
        case whenInUse
        case always
    }

    private(set) var authorization: Authorization = .notDetermined
    private(set) var isUpdating = false
    private(set) var lastError: String?

    /// Called on every accepted location, on the main actor.
    var onFix: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()
    private var distanceFilterM: Double = 15

    override init() {
        super.init()
        manager.delegate = self
        applyConfiguration()
        authorization = Self.map(manager.authorizationStatus)
    }

    /// The configuration actually in force, recorded into each activity so a
    /// field-test result can be traced to a setup rather than to a memory.
    var nativeConfig: ActivityPackageConfig {
        ActivityPackageConfig(
            desiredAccuracy: "kCLLocationAccuracyBest",
            distanceFilterM: distanceFilterM,
            activityType: "fitness",
            pausesAutomatically: manager.pausesLocationUpdatesAutomatically,
            allowsBackgroundUpdates: manager.allowsBackgroundLocationUpdates
        )
    }

    private func applyConfiguration() {
        // Best, not BestForNavigation: the latter keeps the radio in a
        // turn-by-turn duty cycle meant for driving, which costs battery a
        // walker does not get value from.
        manager.desiredAccuracy = kCLLocationAccuracyBest

        // Distance rather than time: the OS then coalesces fixes at a low power
        // level and only wakes this process when the walker has actually moved.
        // At 15 m and walking pace that is roughly one callback every 13 s.
        manager.distanceFilter = distanceFilterM

        // Tells the OS this is human-powered movement, which is what lets it
        // choose sensible sensor duty cycles rather than assuming a vehicle.
        manager.activityType = .fitness

        // Auto-pause exists to save power when the OS thinks movement stopped.
        // For a recording that must be continuous it silently creates gaps —
        // and a gap in a track cannot be recovered afterwards.
        manager.pausesLocationUpdatesAutomatically = false
    }

    func setDistanceFilter(_ metres: Double) {
        distanceFilterM = metres
        manager.distanceFilter = metres
    }

    // MARK: - Authorization

    /// Ask for When In Use, never Always.
    ///
    /// With the location background mode declared, When In Use is enough to
    /// keep recording with the screen locked — iOS shows the blue indicator
    /// instead. Always would additionally allow relaunch-on-location, which
    /// this app does not need, and it draws a stricter review.
    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdates() {
        guard authorization == .whenInUse || authorization == .always else {
            requestAuthorization()
            return
        }
        // Guarded rather than assumed. Setting this without the `location`
        // background mode in Info.plist raises an Objective-C exception, which
        // in Swift is an unrecoverable crash — and a build can lose that key
        // silently, as this one did. Foreground recording still beats the app
        // dying at the trailhead, so the capability is checked and its absence
        // reported instead.
        if Self.declaresLocationBackgroundMode {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        } else {
            lastError = "This build cannot record with the screen off: the location background mode is missing."
        }

        manager.startUpdatingLocation()
        isUpdating = true
    }

    /// Whether this build actually declares the background mode it needs.
    static let declaresLocationBackgroundMode: Bool = {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") ?? false
    }()

    func stopUpdates() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isUpdating = false
    }

    // MARK: - CLLocationManagerDelegate
    //
    // The callbacks are `nonisolated` because the protocol is, then hop back
    // via `assumeIsolated`. That is sound rather than a workaround: Core
    // Location delivers on the queue the manager was created on, and this
    // manager is created in `init`, which is main-actor isolated. The assume
    // traps rather than races if that ever stops being true.

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didChangeAuthorization status: CLAuthorizationStatus
    ) {
        MainActor.assumeIsolated {
            authorization = Self.map(status)
            // Permission can be revoked mid-walk from Settings; surfacing it
            // beats a recording that quietly stops producing fixes.
            if authorization == .denied, isUpdating {
                stopUpdates()
                lastError = "Location permission was withdrawn."
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            // The OS may deliver several at once after a gap; all of them are
            // real observations and all are recorded.
            for location in locations { onFix?(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A transient `.locationUnknown` is normal indoors and under cover —
        // Core Location keeps trying, so it must not tear down the session.
        if (error as? CLError)?.code == .locationUnknown { return }
        MainActor.assumeIsolated {
            lastError = error.localizedDescription
        }
    }

    private static func map(_ status: CLAuthorizationStatus) -> Authorization {
        switch status {
        case .authorizedAlways: .always
        case .authorizedWhenInUse: .whenInUse
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }
}

/// Mirrors `ActivityPackage.NativeConfig` without importing it here, so the
/// provider stays free of TripCore and can be lifted into a plugin later.
struct ActivityPackageConfig {
    let desiredAccuracy: String
    let distanceFilterM: Double
    let activityType: String
    let pausesAutomatically: Bool
    let allowsBackgroundUpdates: Bool
}
