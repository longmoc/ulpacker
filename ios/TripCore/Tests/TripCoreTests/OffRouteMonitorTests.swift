import Foundation
import Testing
@testable import TripCore

/// The off-route monitor's handling of *absence* — poor fixes, no fixes, and
/// the thresholds a trip carries. The presence case (a walker genuinely off the
/// line) is exercised end to end in the recording tests; this file pins the
/// edges the review found, where the state was wrong precisely because nothing
/// was arriving to correct it.
struct OffRouteMonitorTests {
    static func match(offsetM: Double = 5, confidence: RouteMatcher.Confidence) -> RouteMatcher.Match {
        RouteMatcher.Match(
            routeDistanceM: 1_000, offsetM: offsetM,
            lat: 45.9, lng: 6.8, ele: nil, confidence: confidence, progressM: 0
        )
    }

    static func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    // MARK: - No fix ever (the ?? .infinity bug)

    @Test func aPoorFirstFixIsAcquiringNotNoFix() {
        var monitor = OffRouteMonitor()
        // The first thing the monitor ever sees is unusable. There is no prior
        // fix to have gone stale, so this is "still acquiring", not "lost GPS".
        let update = monitor.update(match: Self.match(confidence: .lost), accuracyM: 100, at: Self.at(0))
        #expect(update.state == .acquiring)
        #expect(!update.didEnterNoFix)
    }

    @Test func poorFixesBecomeNoFixOnlyAfterTheTimeout() {
        var monitor = OffRouteMonitor()
        _ = monitor.update(match: Self.match(confidence: .lost), accuracyM: 100, at: Self.at(0))
        // Still within the window: acquiring, not yet given up on.
        let early = monitor.update(match: Self.match(confidence: .lost), accuracyM: 100, at: Self.at(100))
        #expect(early.state == .acquiring)
        // Past 120 s of nothing usable: an explicit no-fix, announced once.
        let late = monitor.update(match: Self.match(confidence: .lost), accuracyM: 100, at: Self.at(130))
        #expect(late.state == .noFix)
        #expect(late.didEnterNoFix)
    }

    @Test func aDegradedStateFollowsAGoodFixNotAColdStart() {
        var monitor = OffRouteMonitor()
        // A usable fix first…
        _ = monitor.update(match: Self.match(offsetM: 5, confidence: .tracking), accuracyM: 8, at: Self.at(0))
        // …then a poor one shortly after: fixes are arriving but too rough to
        // judge with, which is `degraded`, distinct from never having had one.
        let update = monitor.update(match: Self.match(confidence: .lost), accuracyM: 100, at: Self.at(20))
        #expect(update.state == .degraded)
    }

    // MARK: - No fix at all (time-driven, issue 2.2)

    @Test func silenceAfterAGoodFixBecomesNoFix() {
        var monitor = OffRouteMonitor()
        _ = monitor.update(match: Self.match(offsetM: 5, confidence: .tracking), accuracyM: 8, at: Self.at(0))
        #expect(monitor.state == .onRoute)

        // No new fix arrives. A tick inside the window changes nothing…
        let quiet = monitor.evaluate(at: Self.at(60))
        #expect(quiet.state == .onRoute)
        #expect(!quiet.didEnterNoFix)

        // …but past the timeout the stale "on route" must give way to no-fix,
        // announced exactly once.
        let lost = monitor.evaluate(at: Self.at(121))
        #expect(lost.state == .noFix)
        #expect(lost.didEnterNoFix)
        let again = monitor.evaluate(at: Self.at(140))
        #expect(again.state == .noFix)
        #expect(!again.didEnterNoFix)
    }

    @Test func evaluateBeforeAnyFixWaitsBeforeGivingUp() {
        var monitor = OffRouteMonitor()
        // First contact is a bare tick — recording started, no fix yet.
        let early = monitor.evaluate(at: Self.at(0))
        #expect(early.state == .acquiring)
        // Still nothing after the timeout: honestly no-fix.
        let late = monitor.evaluate(at: Self.at(121))
        #expect(late.state == .noFix)
    }

    // MARK: - Per-trip thresholds (issue 3.1)

    @Test func usesTheTripsThresholdsWhenTheyAreSound() {
        let config = OffRouteMonitor.Configuration(
            navigationDefaults: .init(offRouteEnterM: 150, offRouteExitM: 90)
        )
        #expect(config.enterM == 150)
        #expect(config.exitM == 90)
    }

    @Test func fallsBackToDefaultsWhenExitIsNotBelowEnter() {
        let defaults = OffRouteMonitor.Configuration()
        // Exit at or above enter would erase the hysteresis — reject it.
        let inverted = OffRouteMonitor.Configuration(
            navigationDefaults: .init(offRouteEnterM: 60, offRouteExitM: 80)
        )
        #expect(inverted.enterM == defaults.enterM)
        #expect(inverted.exitM == defaults.exitM)
    }

    @Test func fallsBackToDefaultsForNonPositiveThresholds() {
        let defaults = OffRouteMonitor.Configuration()
        let zeroed = OffRouteMonitor.Configuration(
            navigationDefaults: .init(offRouteEnterM: 0, offRouteExitM: 0)
        )
        #expect(zeroed.enterM == defaults.enterM)
        #expect(zeroed.exitM == defaults.exitM)
    }
}
