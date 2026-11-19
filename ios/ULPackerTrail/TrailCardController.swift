// ActivityKit's `Activity` predates strict concurrency and is not marked
// Sendable, though its update and end are meant to be called from anywhere.
@preconcurrency import ActivityKit
import Foundation
import TripCore

/// Keeps the lock-screen card in step with the walk — sparingly.
///
/// Every update has the system redraw the card, so it is pushed only when what
/// it shows would visibly change:
///
///   * the walker has moved 25 m — measured on the ground, not along the
///     route, because a walker leaving the line barely moves along it, and the
///     card used to stand still from the moment they left;
///   * the route turns: its direction ahead has swung 30° since the last
///     push, so a bend shows as it comes rather than after it;
///   * the status has changed (off the route, back on it, arrived);
///   * ten minutes have passed, so a long rest does not have the card declare
///     itself "not updating".
///
/// Standing still otherwise pushes nothing; the card shows clock times, which
/// do not go stale at a rest. Off unless the walker turns it on, so the
/// battery cost can be measured walk against walk rather than assumed.
@MainActor
final class TrailCardController {
    static let enabledKey = "trailCard.enabled"

    /// Moved this far and the picture has visibly shifted: about 20 s at a
    /// walk. Below the GPS's own 15 m step there is nothing new to show.
    static let refreshM = 25.0
    /// A turn of the route ahead this sharp is worth showing straight away.
    static let refreshTurnDegrees = 30.0
    /// Refreshed at least this often, standing or not.
    static let keepAliveS: TimeInterval = 10 * 60
    /// Past this with no update, the card says it is not updating rather than
    /// showing an old position as if it were current. Well beyond the
    /// keep-alive, so only an app that has stopped gets there.
    static let staleAfterS: TimeInterval = 25 * 60

    private var activity: Activity<TrailCardAttributes>?
    private var lastFix: (lat: Double, lng: Double)?
    private var lastHeading: Double?
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
            let started = try Activity.request(
                attributes: TrailCardAttributes(tripName: tripName),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfterS)),
                pushType: nil
            )
            Self.startedHere.insert(started.id)
            activity = started
            remember(state)
        } catch {
            activity = nil
        }
    }

    /// Whether a redraw is worth it; the caller builds the card only if so.
    func wantsUpdate(fix: (lat: Double, lng: Double), heading: Double?, status: TrailCardState.Status) -> Bool {
        guard let activity, activity.activityState == .active else { return false }
        // Arriving is decided while building the card, so the quick check before
        // building reads it as on the route; and the end of a day is within the
        // refresh anyway. The first fix always replaces "waiting".
        let shown: TrailCardState.Status? = lastStatus == .arrived ? .onRoute : lastStatus
        if status != shown { return true }
        if Date().timeIntervalSince(lastPushAt) >= Self.keepAliveS { return true }
        guard let lastFix else { return true }
        if ActivityJournal.haversine(lastFix.lat, lastFix.lng, fix.lat, fix.lng) >= Self.refreshM { return true }
        if let heading, let lastHeading {
            var turn = abs(heading - lastHeading).truncatingRemainder(dividingBy: 360)
            if turn > 180 { turn = 360 - turn }
            if turn >= Self.refreshTurnDegrees { return true }
        }
        return false
    }

    func update(_ state: TrailCardState, fix: (lat: Double, lng: Double), heading: Double?) {
        guard let activity else { return }
        lastFix = fix
        lastHeading = heading
        remember(state)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfterS))
        Task { @MainActor in await activity.update(content) }
    }

    /// Cards left by an earlier run of the app. Nothing updates them — the
    /// process that owned them is gone — so they would sit on the lock screen
    /// showing a stale position, and a recovered walk would put a second card
    /// beside them. Called once at launch, before any walk can start.
    static func endLeftovers() async {
        for activity in Activity<TrailCardAttributes>.activities where !startedHere.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Cards this run of the app started, which are not leftovers whenever
    /// the launch-time sweep happens to get round to running.
    private static var startedHere: Set<String> = []

    func end() {
        guard let activity else { return }
        self.activity = nil
        lastFix = nil
        lastHeading = nil
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
