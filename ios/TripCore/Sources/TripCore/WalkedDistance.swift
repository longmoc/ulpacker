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

    /// Faster than this between two fixes is not walking.
    ///
    /// 5.5 m/s is ~20 km/h — above any walk or trail run, and below the cable
    /// car at Les Houches, the itinerary's shuttle days, and the kind of GPS
    /// spike that flings a fix hundreds of metres in one interval. Distance
    /// covered at vehicle speed is real travel but it is not walking, and the
    /// readout promises the latter.
    public static let maxWalkedSpeedMPS = 5.5

    /// Longer than this between two fixes and the pair is not bridged.
    ///
    /// A gap this size means the walker was stationary long enough that no fix
    /// fired — a break, a pause nobody registered, a night at a refuge — or the
    /// receiver dropped out. In none of those cases did they walk the straight
    /// line between the two points, so it is not counted. Erring toward
    /// under-counting is deliberate: a distance-walked figure earns trust by
    /// never being inflated by something that was not walked.
    public static let maxStepGapS = 300.0

    /// With no receiver speed to vouch for movement, the fastest a step may be.
    ///
    /// A fix without a speed is the receiver saying it does not know whether
    /// the walker is moving — which is exactly the state of a phone indoors.
    /// On the 12 October walk the GPS inside a building hopped 33 m back and
    /// forth with no speed and 20–26 m accuracy, and every hop was banked:
    /// +172 m, 23 % of the walk, standing still. Without a speed, a step must
    /// be both bigger than the two fixes' combined error and no faster than a
    /// brisk walk.
    public static let maxUnvouchedSpeedMPS = 3.0

    /// The distance between two consecutive fixes, or zero if the pair says
    /// nothing about *walking* specifically — as opposed to travel, drift, or a
    /// glitch.
    public static func step(
        from previous: ActivityPackage.Fix, to next: ActivityPackage.Fix
    ) -> Double {
        if let speed = next.speed, speed >= 0, speed < stationarySpeedMPS { return 0 }
        // The receiver measured vehicle speed: a ride, not a walk, whatever the
        // positions say. Covers the stretch of a motorbike ride slow enough
        // that the implied-speed check below would let it through.
        if let speed = next.speed, speed > maxWalkedSpeedMPS { return 0 }

        let seconds = next.t.timeIntervalSince(previous.t)
        // Time did not advance (a reordered or duplicated fix), or the pair
        // straddles a gap too long to be a measured walk. Either way there is
        // no straight line here worth trusting.
        guard seconds > 0, seconds <= maxStepGapS else { return 0 }

        let metres = ActivityJournal.haversine(
            previous.lat, previous.lng, next.lat, next.lng
        )
        if metres < minimumStepM { return 0 }
        // A cable car, a shuttle, or a spike: covered at a speed no walker holds.
        if metres / seconds > maxWalkedSpeedMPS { return 0 }
        if next.speed == nil || (next.speed ?? 0) < 0 {
            let combinedError = max(0, previous.hAcc) + max(0, next.hAcc)
            if metres <= combinedError || metres / seconds > maxUnvouchedSpeedMPS { return 0 }
        }
        return metres
    }

    /// The whole walk, from every fix worth trusting.
    public static func total(of fixes: [ActivityPackage.Fix], maxAccuracyM: Double) -> Double {
        let usable = fixes.filter { $0.isUsable(maxAccuracyM: maxAccuracyM) }
        return zip(usable, usable.dropFirst()).reduce(0) { $0 + step(from: $1.0, to: $1.1) }
    }
}
