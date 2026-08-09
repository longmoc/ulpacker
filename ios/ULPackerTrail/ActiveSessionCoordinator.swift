import Foundation
import Observation
import TripCore

/// Owns the one recording that may be in progress, for the whole app.
///
/// The recorder used to live in `@State` on `TrailMapScreen`, which made the
/// view the owner of a navigation-critical, background-running thing. Pressing
/// Back popped the screen, SwiftUI tore the `@State` down, and the walk stopped
/// with whatever was buffered still in memory. A recording must outlive the
/// screen that happens to be showing it, so it lives here, held by the app, and
/// the screen merely attaches to it.
///
/// The other job is exclusivity: there is exactly one `recorder`, so a walk
/// cannot be started on a second trip while one is already running. A screen
/// asks whether it is blocked before offering Start.
@MainActor
@Observable
final class ActiveSessionCoordinator {
    /// The recorder the app is holding, if any. It exists while a trip screen is
    /// open (idle, ready to Start) and — the point of this class — keeps existing
    /// after that screen is popped for as long as a walk is `isActive`.
    private(set) var recorder: TrailRecorder?

    /// A recovery decision waiting to be made, surfaced at the app root rather
    /// than buried inside whichever trip happens to be opened.
    var recovery: Recovery?

    /// The trip id the app wants to navigate to — set when the user chooses to
    /// continue a recovered walk, so the root can push the right screen. Kept as
    /// the id (Hashable) rather than the package so it drives
    /// `navigationDestination(item:)`; the package comes from `recorder`.
    var openTarget: String?

    enum Recovery: Identifiable {
        /// An unfinished walk whose trip and revision are still on the phone, so
        /// it can be reopened against the exact route it was recorded on.
        case resumable(ActivityJournal, TripPackage)
        /// An unfinished walk whose trip or revision is gone. It must never be
        /// forced onto another route; the only safe choices are keep or discard.
        case orphaned(ActivityJournal)

        var id: String {
            switch self {
            case .resumable(let journal, _): journal.session.activityId
            case .orphaned(let journal): journal.session.activityId
            }
        }
    }

    // MARK: - Attaching a screen

    /// Hand the screen for `package` the recorder it should drive.
    ///
    /// If a walk is already active for this trip, that same recorder comes back,
    /// so re-opening the screen re-attaches to the walk in progress rather than
    /// starting a blank one. If a *different* trip is recording, that recorder is
    /// left untouched and a throwaway idle one is returned so the screen can
    /// still render — `isBlocked(for:)` tells it not to offer Start. Otherwise a
    /// fresh idle recorder is created and adopted.
    func recorder(for package: TripPackage) -> TrailRecorder {
        if let recorder, recorder.tripId == package.tripId {
            return recorder
        }
        if let recorder, recorder.isActive {
            // Another trip is mid-walk: do not disturb it, and do not adopt this
            // one — adopting would drop the active walk from the single slot.
            return TrailRecorder(package: package)
        }
        let fresh = TrailRecorder(package: package)
        recorder = fresh
        return fresh
    }

    /// A walk is running on a different trip, so this one may not start.
    func isBlocked(for package: TripPackage) -> Bool {
        guard let recorder, recorder.isActive else { return false }
        return recorder.tripId != package.tripId
    }

    /// Stop holding a recorder once the user has finished with it — the summary
    /// dismissed, or the walk discarded — so the slot is free for the next trip.
    func release(_ recorder: TrailRecorder) {
        guard self.recorder === recorder, !recorder.isActive else { return }
        self.recorder = nil
    }

    /// Commit whatever the active walk has buffered. Called when the app is about
    /// to lose the foreground, from the root, so it works regardless of which
    /// screen is showing.
    func flushForBackgrounding() {
        recorder?.flushForBackgrounding()
    }

    // MARK: - Recovery

    /// Look for an unfinished walk and, if there is one, classify it against the
    /// trips on the phone. Matching needs both `tripId` and `tripRevision`: a
    /// re-exported trip may have moved the line, so an old journal's metres would
    /// no longer mean the same thing on the new revision.
    func detectRecovery(in library: TripLibrary) {
        guard recovery == nil, recorder?.isActive != true,
              let journal = try? ActivityJournal.pendingSessions(
                in: TrailRecorder.activitiesRoot
              ).first
        else { return }

        let match = library.package(
            tripId: journal.session.tripId,
            revision: journal.session.tripRevision
        )
        recovery = match.map { .resumable(journal, $0) } ?? .orphaned(journal)
    }

    /// Continue a recovered walk: adopt a recorder for its trip, resume against
    /// the exact package, and ask the root to open that trip's screen.
    func continueRecovery(_ journal: ActivityJournal, package: TripPackage) {
        let recorder = TrailRecorder(package: package)
        self.recorder = recorder
        recorder.resumeCrashedSession(journal)
        recovery = nil
        openTarget = package.tripId
    }

    /// Throw away a recovered walk the user does not want kept.
    func discardRecovery(_ journal: ActivityJournal) {
        try? journal.delete()
        recovery = nil
    }
}
