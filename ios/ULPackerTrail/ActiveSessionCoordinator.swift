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

    /// The unfinished walk on disk, whether or not the walker has been asked
    /// about it. The prompt alone was not enough: answering "Not now" left the
    /// walk with no way back to it short of killing the app, and on 19 November
    /// a paused walk looked lost. The trip screens offer it from this instead.
    private(set) var unfinished: Recovery?
    /// The walk last put off with "Not now", so coming back to the app does
    /// not ask about it again; the trip screens still offer it.
    private var postponedId: String?

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

    /// Called when the app comes forward: the recorder holds screen updates back
    /// while it is in the background.
    func showLatestProgress() {
        recorder?.showLatestProgress()
    }

    // MARK: - Recovery

    /// Look for an unfinished walk and, if there is one, classify it against the
    /// trips on the phone. Matching needs both `tripId` and `tripRevision`: a
    /// re-exported trip may have moved the line, so an old journal's metres would
    /// no longer mean the same thing on the new revision.
    ///
    /// Run at launch and every time the app comes forward; it asks only about a
    /// walk not already put off.
    func detectRecovery(in library: TripLibrary) {
        guard recorder?.isActive != true,
              let journal = try? ActivityJournal.pendingSessions(in: TrailRecorder.activitiesRoot).first
        else {
            if recorder?.isActive != true { unfinished = nil }
            return
        }
        let match = library.package(tripId: journal.session.tripId, revision: journal.session.tripRevision)
        let found: Recovery = match.map { .resumable(journal, $0) } ?? .orphaned(journal)
        unfinished = found
        if recovery == nil, found.id != postponedId { recovery = found }
    }

    /// "Not now": stop asking about this walk; it stays on the trip screens.
    func postponeRecovery() {
        postponedId = recovery?.id
        recovery = nil
    }

    /// The unfinished walk on `package`, if it can be continued there.
    func unfinishedWalk(for package: TripPackage) -> ActivityJournal? {
        guard case .resumable(let journal, let walkPackage) = unfinished,
              walkPackage.tripId == package.tripId, walkPackage.revision == package.revision
        else { return nil }
        return journal
    }

    /// An unfinished walk on some other trip, which a new walk here must not
    /// be started over.
    func unfinishedElsewhere(than package: TripPackage) -> Recovery? {
        guard let unfinished, unfinishedWalk(for: package) == nil else { return nil }
        return unfinished
    }

    /// Continue a recovered walk: resume it against the exact package and ask
    /// the root to open that trip's screen. From that trip's own screen, its
    /// recorder is reused and nothing is pushed — a second recorder would leave
    /// the open screen showing an idle walk while the real one ran unseen.
    func continueRecovery(_ journal: ActivityJournal, package: TripPackage, openScreen: Bool = true) {
        let recorder: TrailRecorder
        if let held = self.recorder, held.tripId == package.tripId, !held.isActive {
            recorder = held
        } else {
            recorder = TrailRecorder(package: package)
            self.recorder = recorder
        }
        recorder.resumeCrashedSession(journal)
        recovery = nil
        unfinished = nil
        if openScreen { openTarget = package.tripId }
    }

    /// Throw away a recovered walk the user does not want kept.
    func discardRecovery(_ journal: ActivityJournal) {
        try? journal.delete()
        recovery = nil
        if unfinished?.id == journal.session.activityId { unfinished = nil }
    }
}
