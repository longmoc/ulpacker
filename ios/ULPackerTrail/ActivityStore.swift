import Foundation
import Observation
import TripCore

/// The walks already recorded on this phone.
///
/// Reads the same directory the recorder writes to, so there is one copy of a
/// walk and no import step between finishing one and seeing it. Drive sync
/// (§7 M7) will push these files as they are; nothing here is a staging format.
@MainActor
@Observable
final class ActivityStore {
    private(set) var activities: [ActivityPackage] = []

    static var root: URL {
        URL.documentsDirectory.appendingPathComponent("activities", isDirectory: true)
    }

    func reload() {
        activities = (try? ActivityJournal.finishedActivities(in: Self.root)) ?? []
    }

    func activities(for package: TripPackage) -> [ActivityPackage] {
        activities.filter { $0.tripId == package.tripId }
    }

    /// The best battery measurement this trip has produced, or nil if none has
    /// yet run long enough to be worth quoting.
    ///
    /// "Best" is the longest, not the latest. A rate measured over six hours
    /// says more than one measured over forty minutes, and the forecast built
    /// on it is only as good as its worst input.
    func batteryRate(for package: TripPackage) -> Power.Report? {
        activities(for: package)
            .compactMap(\.power)
            .filter(\.isReliable)
            .max { $0.dischargeS < $1.dischargeS }
    }

    /// Delete a walk, journal and all. The only way one leaves this device.
    func delete(_ activity: ActivityPackage) {
        let directory = Self.root.appendingPathComponent(activity.activityId, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        reload()
    }
}
