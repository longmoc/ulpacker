// ActivityKit's `Activity` predates strict concurrency and is not marked
// Sendable, though its update and end are meant to be called from anywhere.
@preconcurrency import ActivityKit
import Foundation
import TripCore

/// Keeps the lock-screen card in step with the walk — sparingly.
///
/// Every update has the system redraw the card, so it is pushed only when what
/// it shows would visibly change: the walker has gone another 50 m along the
/// route (the path ahead has moved under them), the status has changed (off the
/// route, back on it, arrived), or, while off the route, a minute has passed
/// and the distance back has moved on. Standing still pushes nothing; the card
/// shows clock times, which do not go stale at a rest.
///
/// Off unless the walker turns it on, so the battery cost can be measured walk
/// against walk rather than assumed.
@MainActor
final class TrailCardController {
    static let enabledKey = "trailCard.enabled"

    /// Further along the route than this and the path ahead has visibly moved.
    static let refreshM = 50.0
    /// While off the route, the distance back is worth refreshing this often.
    static let offRouteRefreshS: TimeInterval = 60
    /// Past this with no update, the card says it is not updating rather than
    /// showing an old position as if it were current.
    static let staleAfterS: TimeInterval = 15 * 60

    private var activity: Activity<TrailCardAttributes>?
    private var lastRouteM: Double?
    private var lastStatus: TrailCardState.Status?
    private var lastNext: String?
    private var lastPushAt = Date.distantPast

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var isAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Starts the card if it is wanted and not already showing. Only works with
    /// the app in front — iOS allows starting a Live Activity from nowhere else
    /// — so it is called on starting, resuming and the app coming forward,
    /// which also replaces a card the system ended after its eight hours.
    func showIfWanted(tripName: String, state: TrailCardState) {
        guard Self.isEnabled, Self.isAllowed else { return }
        if let activity, activity.activityState == .active { return }
        do {
            activity = try Activity.request(
                attributes: TrailCardAttributes(tripName: tripName),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfterS)),
                pushType: nil
            )
            remember(state)
        } catch {
            activity = nil
        }
    }

    /// Whether `state` is worth a redraw; the caller builds it only if so.
    func wantsUpdate(routeM: Double, status: TrailCardState.Status) -> Bool {
        guard let activity, activity.activityState == .active else { return false }
        // Arriving is decided while building the card, so the quick check before
        // building reads it as on the route; and the end of a day is within the
        // 50 m refresh anyway. The first fix always replaces "waiting".
        let shown: TrailCardState.Status? = lastStatus == .arrived ? .onRoute : lastStatus
        if status != shown { return true }
        if status == .offRoute || status == .approaching {
            return Date().timeIntervalSince(lastPushAt) >= Self.offRouteRefreshS
        }
        guard let lastRouteM else { return true }
        return abs(routeM - lastRouteM) >= Self.refreshM
    }

    func update(_ state: TrailCardState, routeM: Double) {
        guard let activity else { return }
        lastRouteM = routeM
        if state.next == lastNext, state.status == lastStatus, Date().timeIntervalSince(lastPushAt) < 1 { return }
        remember(state)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfterS))
        Task { @MainActor in await activity.update(content) }
    }

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastRouteM = nil
        lastStatus = nil
        lastNext = nil
        Task { @MainActor in await activity.end(nil, dismissalPolicy: .immediate) }
    }

    private func remember(_ state: TrailCardState) {
        lastStatus = state.status
        lastNext = state.next
        lastPushAt = Date()
    }
}
