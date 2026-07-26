import Foundation
import Testing
@testable import TripCore

/// A finished walk survives, and stops being mistaken for an interrupted one.
///
/// Both halves matter and they are the same bug seen from two sides: nothing
/// on disk said whether a session had been closed out. So a completed walk was
/// deleted by the next tap, and a completed walk left alone was offered back
/// every launch as "shall I continue?".
struct ActivityHistoryTests {
    static func makeRoot() throws -> URL {
        let root = URL.temporaryDirectory
            .appendingPathComponent("activities-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func journal(in root: URL, id: String = UUID().uuidString, startedAt: Date = Date()) throws -> ActivityJournal {
        try ActivityJournal.create(
            in: root,
            session: .init(
                activityId: id,
                tripId: "trip",
                tripRevision: 1,
                stageId: nil,
                startedAt: startedAt,
                nativeConfig: .init(
                    desiredAccuracy: "best",
                    distanceFilterM: 15,
                    activityType: "fitness",
                    pausesAutomatically: false,
                    allowsBackgroundUpdates: true
                )
            )
        )
    }

    @Test func aWalkIsStillThereAfterItEnds() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try Self.journal(in: root)

        try journal.append(contentsOf: [
            .init(seq: 1, t: Date(timeIntervalSince1970: 0), lat: 45.9, lng: 6.8, hAcc: 5),
            .init(seq: 2, t: Date(timeIntervalSince1970: 600), lat: 45.91, lng: 6.81, hAcc: 5)
        ])
        let package = try journal.makePackage(
            status: .finished, endedAt: Date(timeIntervalSince1970: 600), maxAccuracyM: 50
        )
        try journal.commit(package)

        let kept = try #require(try ActivityJournal.finishedActivities(in: root).first)
        #expect(kept.stats.fixCount == 2)
        #expect(kept.stats.distanceM == package.stats.distanceM)
    }

    @Test func aFinishedWalkIsNotOfferedAsAnInterruptedOne() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try Self.journal(in: root)
        try journal.append(.init(seq: 1, t: Date(), lat: 45.9, lng: 6.8, hAcc: 5))

        // Before it is closed out it is exactly what recovery is for.
        #expect(try ActivityJournal.pendingSessions(in: root).count == 1)
        #expect(!journal.isFinished)

        try journal.commit(
            try journal.makePackage(status: .finished, endedAt: Date(), maxAccuracyM: 50)
        )

        #expect(journal.isFinished)
        #expect(try ActivityJournal.pendingSessions(in: root).isEmpty)
    }

    @Test func aCrashedWalkIsStillOfferedBack() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try Self.journal(in: root)
        try journal.append(.init(seq: 1, t: Date(), lat: 45.9, lng: 6.8, hAcc: 5))
        // No commit — the app died. The journal is all that is left and it must
        // still be recoverable, which is the case the whole design exists for.
        #expect(try ActivityJournal.pendingSessions(in: root).count == 1)
        #expect(try ActivityJournal.finishedActivities(in: root).isEmpty)
    }

    @Test func historyReadsNewestFirst() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (index, day) in [3.0, 1.0, 2.0].enumerated() {
            let started = Date(timeIntervalSince1970: day * 86_400)
            let journal = try Self.journal(in: root, id: "a\(index)", startedAt: started)
            try journal.append(.init(seq: 1, t: started, lat: 45.9, lng: 6.8, hAcc: 5))
            try journal.commit(
                try journal.makePackage(
                    status: .finished, endedAt: started.addingTimeInterval(3600), maxAccuracyM: 50
                )
            )
        }
        let starts = try ActivityJournal.finishedActivities(in: root).map(\.startedAt)
        #expect(starts == starts.sorted(by: >))
    }

    // MARK: - Power in the journal

    @Test func batterySamplesSurviveIntoTheFinishedWalk() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try Self.journal(in: root)

        try journal.appendPower(contentsOf: (0...4).map { step in
            .init(
                t: Date(timeIntervalSince1970: Double(step) * 3600),
                level: 1.0 - Double(step) * 0.04,
                charging: false,
                foreground: false,
                lowPowerMode: false,
                thermal: "nominal"
            )
        })
        try journal.append(.init(seq: 1, t: Date(timeIntervalSince1970: 0), lat: 45.9, lng: 6.8, hAcc: 5))

        let package = try journal.makePackage(status: .finished, endedAt: Date(), maxAccuracyM: 50)
        let power = try #require(package.power)
        #expect(abs(try #require(power.percentPerHour) - 4) < 0.01)
        #expect(power.isReliable)
    }

    @Test func aWalkWithNoBatteryDataStillFinishes() throws {
        // The simulator reports no battery level at all, and an old activity
        // has no samples. Neither is a reason to fail.
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try Self.journal(in: root)
        try journal.append(.init(seq: 1, t: Date(), lat: 45.9, lng: 6.8, hAcc: 5))
        let package = try journal.makePackage(status: .finished, endedAt: Date(), maxAccuracyM: 50)
        #expect(package.power == nil)
        try journal.commit(package)
        #expect(try ActivityJournal.finishedActivities(in: root).count == 1)
    }

    // MARK: - The trip ahead

    @Test func forecastsEveryDayOfTheTripFromAMeasuredRate() throws {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let forecast = BatteryForecast.make(
            package: package,
            profile: RouteProfile(package: package),
            percentPerHour: 5
        )

        #expect(forecast.days.count == 9)
        // Day one is 18.9 km and 1530 m of climb — about 8 hours by the same
        // estimate the stop details use, so about 40 points at 5%/h.
        let first = try #require(forecast.days.first)
        #expect(abs(first.percent - first.hours * 5) < 0.11)
        #expect(first.percent > 30 && first.percent < 45)
        #expect(!first.exceedsFullCharge)

        // Every day at once is what makes it a trip rather than a walk.
        #expect(forecast.totalPercent > 250)
        #expect(forecast.chargesNeeded > 3)
    }

    @Test func namesTheDayThatDecidesIt() throws {
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let forecast = BatteryForecast.make(
            package: package, profile: RouteProfile(package: package), percentPerHour: 5
        )
        let worst = try #require(forecast.worstDay)
        #expect(forecast.days.allSatisfy { $0.percent <= worst.percent })
    }

    @Test func flagsADayOneChargeWillNotCover() throws {
        // At 12%/h — roughly what a phone costs with the screen on — the long
        // days stop fitting inside a single charge, and that is the whole
        // reason to compute this before leaving rather than at the col.
        let package = try TripPackage.decode(from: TripPackageTests.fixtureData("tmb-ccw"))
        let forecast = BatteryForecast.make(
            package: package, profile: RouteProfile(package: package), percentPerHour: 12
        )
        #expect(forecast.days.contains { $0.exceedsFullCharge })
        // And at a realistic pocket rate, none of them do.
        let pocket = BatteryForecast.make(
            package: package, profile: RouteProfile(package: package), percentPerHour: 4
        )
        #expect(!pocket.days.contains { $0.exceedsFullCharge })
    }
}
