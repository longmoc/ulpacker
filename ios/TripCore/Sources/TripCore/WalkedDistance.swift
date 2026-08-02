import Foundation

/// How far the walker actually walked, as opposed to how far along the planned
/// line they have got.
///
/// These are two different numbers and the app showed only one of them under a
/// label that implied the other. Cut a corner and rejoin near the finish and
/// the projection sits near the finish, so progress along the route reads
/// almost complete — correct for "where am I on the line", wrong for "how far
/// have I walked", which is the question the leg-tired end of the day asks.
///
/// Summed from the fixes, with one rule to stop the receiver inventing metres.
public enum WalkedDistance {
    /// Below this the receiver is telling us the walker is not moving.
    ///
    /// Standing still does not usually produce fixes at all — the distance
    /// filter sees to that — but a noisy fix can jump far enough to trip it,
    /// and a phone left on a table at a refuge should not walk to Courmayeur
    /// overnight. Rather than invent a filter, this trusts the speed the
    /// receiver itself reports; a fix with no speed is counted, because
    /// "unknown" is not "stationary".
    public static let stationarySpeedMPS = 0.3

    /// Steps shorter than this are noise whatever the speed says.
    public static let minimumStepM = 2.0

    /// The distance between two consecutive fixes, or zero if the pair says
    /// nothing about walking.
    public static func step(
        from previous: ActivityPackage.Fix, to next: ActivityPackage.Fix
    ) -> Double {
        if let speed = next.speed, speed >= 0, speed < stationarySpeedMPS { return 0 }
        let metres = ActivityJournal.haversine(
            previous.lat, previous.lng, next.lat, next.lng
        )
        return metres < minimumStepM ? 0 : metres
    }

    /// The whole walk, from every fix worth trusting.
    public static func total(of fixes: [ActivityPackage.Fix], maxAccuracyM: Double) -> Double {
        let usable = fixes.filter { $0.isUsable(maxAccuracyM: maxAccuracyM) }
        return zip(usable, usable.dropFirst()).reduce(0) { $0 + step(from: $1.0, to: $1.1) }
    }
}
