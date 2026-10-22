import Foundation
import UserNotifications

/// The one thing this app must do while nobody is looking at it: say, out loud,
/// that the walker has left the route or that the GPS is gone.
///
/// Everything else the trail screen shows is only useful with the screen on. An
/// off-route alert is the opposite — its whole value is the moment the phone is
/// in a pocket and the walker has no reason to look. That needs a real local
/// notification, not an in-app banner nobody will see.
///
/// A protocol so the recorder does not depend on `UNUserNotificationCenter`
/// directly, which keeps the decision of *when* to alert testable in isolation
/// from the platform that delivers it.
@MainActor
protocol TrailNotifier {
    /// Ask once, early — before the trip, not at the moment of an alert, when a
    /// permission sheet is the last thing a lost walker needs.
    func requestAuthorization()
    /// The walker has crossed into off-route. Fired once per crossing.
    func notifyOffRoute()
    /// The GPS has been lost for long enough to report. Fired once per loss.
    func notifyNoFix()
    /// On the line but walking it backwards. Fired once per episode.
    func notifyWrongWay()
}

/// Delivers through `UNUserNotificationCenter`.
///
/// Two deliberate choices: fixed identifiers, so a re-alert replaces its
/// predecessor rather than stacking a column of the same warning; and no
/// foreground presentation delegate, so these stay silent while the app is open
/// — the screen's own status band covers that case — and surface only when the
/// walker cannot see the screen, which is exactly when they are needed.
@MainActor
final class SystemNotifier: TrailNotifier {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyOffRoute() {
        post(
            id: "off-route",
            title: "Off route",
            body: "You seem to have left the planned route."
        )
    }

    func notifyNoFix() {
        post(
            id: "no-fix",
            title: "No GPS fix",
            body: "The phone has lost GPS. Your position is unknown until it returns."
        )
    }

    func notifyWrongWay() {
        post(
            id: "wrong-way",
            title: "Walking against the route",
            body: "You are on the route but heading back the way it came."
        )
    }

    private func post(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A nil trigger delivers as soon as it is scheduled.
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
