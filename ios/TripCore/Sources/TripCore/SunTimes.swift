import Foundation

/// When the sun sets, worked out from position and date alone.
///
/// The question it serves — will I get there before dark — comes up exactly
/// where there is no signal, so this is arithmetic rather than a lookup: the
/// standard sunrise equation, good to a minute or two.
///
/// It is the sun going below a flat horizon. A walker in a deep valley loses
/// the light well before this, so it is the latest the day can last, never a
/// promise of light until then.
public enum SunTimes {
    /// Sunset on the calendar day `date` falls on in `calendar`'s time zone.
    /// Nil when the sun does not set or does not rise that day.
    public static func sunset(
        latitude: Double,
        longitude: Double,
        on date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return nil }

        let radians = Double.pi / 180
        let cycle = julianDayNumber(year: year, month: month, day: dayOfMonth) - 2_451_545.0 + 0.0008
        let meanNoon = cycle - longitude / 360
        let anomaly = (357.5291 + 0.98560028 * meanNoon).truncatingRemainder(dividingBy: 360)
        let m = anomaly * radians
        let centre = 1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m)
        let ecliptic = (anomaly + centre + 180 + 102.9372).truncatingRemainder(dividingBy: 360) * radians
        let transit = 2_451_545.0 + meanNoon + 0.0053 * sin(m) - 0.0069 * sin(2 * ecliptic)
        let declination = asin(sin(ecliptic) * sin(23.4397 * radians))

        // -0.833°: the sun's radius plus the refraction that lifts it.
        let phi = latitude * radians
        let cosHourAngle = (sin(-0.833 * radians) - sin(phi) * sin(declination))
            / (cos(phi) * cos(declination))
        guard abs(cosHourAngle) <= 1 else { return nil }

        let set = transit + acos(cosHourAngle) / radians / 360
        return Date(timeIntervalSince1970: (set - 2_440_587.5) * 86_400)
    }

    /// The Julian day number at noon on a Gregorian date.
    private static func julianDayNumber(year: Int, month: Int, day: Int) -> Double {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return Double(day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045)
    }
}
