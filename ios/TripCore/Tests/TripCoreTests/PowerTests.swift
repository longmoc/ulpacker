import Foundation
import Testing
@testable import TripCore

/// Battery accounting.
///
/// These tests exist because a wrong battery number is worse than none. It is
/// the one figure that decides whether the phone is trusted to record on day
/// six of a nine-day walk, and every failure mode below produces a number that
/// looks perfectly reasonable: a plausible rate derived across a charging
/// period, a plausible rate derived from three minutes of a device that reports
/// in 5% steps, a plausible screen-off figure that quietly includes the twenty
/// minutes spent reading the map.
struct PowerTests {
    func sample(
        _ minutes: Double,
        level: Double,
        charging: Bool = false,
        foreground: Bool = false,
        lowPower: Bool = false,
        thermal: String = "nominal"
    ) -> Power.Sample {
        Power.Sample(
            t: Date(timeIntervalSince1970: minutes * 60),
            level: level,
            charging: charging,
            foreground: foreground,
            lowPowerMode: lowPower,
            thermal: thermal
        )
    }

    // MARK: - The rate

    @Test func derivesTheRateFromLevelAndTime() throws {
        // Four hours, 100% down to 84%: 4 points an hour.
        let samples = (0...8).map { step in
            sample(Double(step) * 30, level: 1.0 - Double(step) * 0.02)
        }
        let report = try #require(Power.report(for: samples))
        #expect(abs(try #require(report.percentPerHour) - 4) < 0.01)
        #expect(report.dischargeS == 4 * 3600)
        #expect(abs(report.drainedPercent - 16) < 0.01)
        #expect(report.isReliable)
    }

    @Test func chargingPeriodsAreExcludedRatherThanAveragedIn() throws {
        // Two hours discharging at 5%/h, then two hours on a refuge socket
        // climbing back up. Counting the plug-in would report a *negative*
        // drain; averaging it in would report about half the real rate, and
        // half is the number that gets someone caught out.
        var samples = [
            sample(0, level: 1.0),
            sample(60, level: 0.95),
            sample(120, level: 0.90)
        ]
        samples += [
            sample(180, level: 0.95, charging: true),
            sample(240, level: 1.00, charging: true)
        ]
        let report = try #require(Power.report(for: samples))
        #expect(report.dischargeS == 2 * 3600)
        #expect(abs(try #require(report.percentPerHour) - 5) < 0.01)
    }

    @Test func aLevelThatRisesOnBatteryCountsAsNoDrain() throws {
        // Reported levels are quantised and occasionally step back up. That is
        // the granularity moving, not energy appearing, and it must not be
        // allowed to subtract from a real measurement.
        let samples = [
            sample(0, level: 0.90),
            sample(60, level: 0.86),
            sample(120, level: 0.87),
            sample(180, level: 0.82)
        ]
        let report = try #require(Power.report(for: samples))
        #expect(abs(report.drainedPercent - 9) < 0.01)
        #expect(try #require(report.percentPerHour) > 0)
    }

    // MARK: - Refusing to answer

    @Test func aShortWalkQuotesNoRateAtAll() throws {
        // Three minutes, one 5% step: arithmetically 100%/hour. A device that
        // reports in coarse steps will produce exactly this within minutes of
        // every walk starting, and it would be the first number anyone saw.
        let samples = [sample(0, level: 1.0), sample(3, level: 0.95)]
        let report = try #require(Power.report(for: samples))
        #expect(report.percentPerHour == nil)
        #expect(!report.isReliable)
        // The evidence is still kept — it is only the conclusion that is withheld.
        #expect(abs(report.drainedPercent - 5) < 0.01)
        #expect(report.dischargeS == 180)
    }

    @Test func aLongButFlatWalkIsNotCalledReliable() throws {
        // Two hours and a single percentage point. The rate is quotable in
        // form but the measurement is one quantisation step wide.
        let samples = [sample(0, level: 1.0), sample(120, level: 0.99)]
        let report = try #require(Power.report(for: samples))
        #expect(report.percentPerHour != nil)
        #expect(!report.isReliable)
    }

    @Test func nothingIsReportedFromASingleReading() {
        #expect(Power.report(for: [sample(0, level: 1.0)]) == nil)
        #expect(Power.report(for: []) == nil)
    }

    // MARK: - Screen on and screen off

    @Test func separatesTheScreenOnCostFromThePocket() throws {
        // An hour in the pocket at 3%/h, then an hour in the hand at 12%/h.
        // The plan asks for these measured separately, and they are the two
        // numbers that answer different questions: one is what recording
        // costs, the other is what looking at the map costs.
        let samples = [
            sample(0, level: 1.00, foreground: false),
            sample(60, level: 0.97, foreground: false),
            sample(120, level: 0.85, foreground: true)
        ]
        // The middle pair straddles the screen coming on, so it belongs to
        // neither side — attributing it either way would be a guess.
        let straddled = try #require(Power.report(for: samples))
        #expect(straddled.backgroundS == 3600)
        #expect(straddled.foregroundS == 0)

        let clean = try #require(
            Power.report(for: [
                sample(0, level: 1.00, foreground: false),
                sample(60, level: 0.97, foreground: false),
                sample(60, level: 0.97, foreground: true),
                sample(120, level: 0.85, foreground: true)
            ])
        )
        #expect(abs(try #require(clean.backgroundPercentPerHour) - 3) < 0.01)
        #expect(abs(try #require(clean.foregroundPercentPerHour) - 12) < 0.01)
        // And the headline still covers the whole walk.
        #expect(abs(try #require(clean.percentPerHour) - 7.5) < 0.01)
    }

    // MARK: - Context

    @Test func keepsTheConditionsThatExplainABadResult() throws {
        let report = try #require(
            Power.report(for: [
                sample(0, level: 1.0, thermal: "nominal"),
                sample(60, level: 0.9, lowPower: true, thermal: "serious"),
                sample(120, level: 0.8, thermal: "fair")
            ])
        )
        // The worst state seen, not the last: a phone that cooked for an hour
        // and recovered explains a drain figure that a final "fair" would not.
        #expect(report.maxThermal == "serious")
        #expect(report.lowPowerModeSeen)
    }

    @Test func outOfOrderSamplesAreSortedRatherThanDiscarded() throws {
        let report = try #require(
            Power.report(for: [
                sample(120, level: 0.90),
                sample(0, level: 1.00),
                sample(60, level: 0.95)
            ])
        )
        #expect(report.dischargeS == 2 * 3600)
        #expect(abs(report.drainedPercent - 10) < 0.01)
    }
}
