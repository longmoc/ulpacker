import Foundation

/// What the lock-screen card shows: the walking screen's readouts and the shape
/// of the path ahead, ready to draw.
///
/// The text is formatted here, in the app, rather than in the widget extension,
/// so the card and the screen cannot drift apart in what they say. Times are
/// clock times — "arrive 17:20", never "3 h 10 left" — because the card is only
/// redrawn when the walker has moved, and a countdown would freeze at a rest.
public struct TrailCardState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case onRoute, approaching, offRoute, wrongWay, weakGPS, paused, arrived, acquiring
    }

    public let status: Status
    /// What the status needs said beside it: how far off, how far to the start.
    public let statusDetail: String?
    public let title: String
    public let next: String?
    public let nextSymbol: String?
    /// The next stop's distance alone, for the narrow space by the Dynamic Island.
    public let nextShort: String?
    public let daylight: String?
    /// 0 plenty of light, 1 under an hour to spare, 2 arriving after dark.
    public let daylightLevel: Int
    public let path: PathAhead?

    public init(
        status: Status, statusDetail: String?, title: String, next: String?, nextSymbol: String?,
        nextShort: String?, daylight: String?, daylightLevel: Int, path: PathAhead?
    ) {
        self.status = status
        self.statusDetail = statusDetail
        self.title = title
        self.next = next
        self.nextSymbol = nextSymbol
        self.nextShort = nextShort
        self.daylight = daylight
        self.daylightLevel = daylightLevel
        self.path = path
    }

    /// What the card shows from the moment the walk starts until the first fix.
    public static func waiting(tripName: String) -> TrailCardState {
        TrailCardState(
            status: .acquiring, statusDetail: nil, title: tripName, next: nil, nextSymbol: nil,
            nextShort: nil, daylight: nil, daylightLevel: 0, path: nil
        )
    }

    /// Less daylight than this at the far end is worth a second look.
    static let tightDaylightS: TimeInterval = 3_600

    public static func make(
        guidance: DayPlanner.Guidance,
        progress: RecordingSession.Progress,
        path: PathAhead?,
        paused: Bool,
        clock: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    ) -> TrailCardState {
        let status: Status
        var detail: String?
        if paused {
            status = .paused
        } else if progress.offRouteState == .approaching {
            status = .approaching
            detail = distance(progress.offsetM) + " to the route"
        } else if progress.confidence == .distant || progress.offRouteState == .offRoute {
            status = .offRoute
            detail = distance(progress.offsetM) + " off"
        } else if progress.isWrongWay {
            status = .wrongWay
        } else if progress.offRouteState == .noFix || progress.offRouteState == .degraded {
            status = .weakGPS
        } else if guidance.arrived {
            status = .arrived
        } else {
            status = .onRoute
        }

        let day = guidance.dayNumber.map { "Day \($0)" } ?? "Route"
        let title = "\(day) · \(km(guidance.doneM)) / \(km(guidance.totalM))"

        // Figures first: on a lock screen the line is cut short, and a long stop
        // name ("Weather gate — Col du Bonhomme…") would push them off the end.
        let stop = guidance.next
        var nextParts = [distance(stop.distanceM) + (stop.isStraightLine ? " straight" : "")]
        if let arrival = stop.arrival { nextParts.append(clock(arrival)) }
        nextParts.append(stop.name)

        var dayParts: [String] = []
        if let ascent = guidance.ascentLeftM, ascent >= 5 { dayParts.append("↑\(Int((ascent / 10).rounded()) * 10) m left") }
        if let arrival = guidance.arrival, !guidance.arrived { dayParts.append("arrive " + clock(arrival)) }
        if let sunset = guidance.sunset { dayParts.append("sunset " + clock(sunset)) }
        let level: Int = switch guidance.spareDaylight {
        case let spare? where spare < 0: 2
        case let spare? where spare < tightDaylightS: 1
        default: 0
        }

        return TrailCardState(
            status: status,
            statusDetail: detail,
            title: title,
            next: guidance.arrived ? nil : nextParts.joined(separator: " · "),
            nextSymbol: stop.kind?.symbolName ?? "flag.checkered",
            nextShort: guidance.arrived ? nil : distance(stop.distanceM),
            daylight: dayParts.isEmpty ? nil : dayParts.joined(separator: " · "),
            daylightLevel: level,
            path: path
        )
    }

    static func km(_ metres: Double?) -> String {
        guard let metres, metres.isFinite else { return "—" }
        return String(format: "%.1f km", metres / 1000)
    }

    static func distance(_ metres: Double) -> String {
        if metres >= 20_000 { return "far" }
        return metres >= 1_000 ? String(format: "%.1f km", metres / 1000) : "\(Int(metres.rounded())) m"
    }
}

#if canImport(ActivityKit) && os(iOS)
import ActivityKit

/// The Live Activity a recording walk shows on the lock screen. Shared by the
/// app, which starts and updates it, and the widget extension, which draws it.
public struct TrailCardAttributes: ActivityAttributes {
    public typealias ContentState = TrailCardState
    public let tripName: String

    public init(tripName: String) {
        self.tripName = tripName
    }
}
#endif

#if canImport(SwiftUI)
import SwiftUI

/// The card itself. Kept here rather than in the widget extension so the app
/// can render the very same view for a check on the simulator, where a lock
/// screen cannot be shown on demand.
public struct TrailCardView: View {
    let tripName: String
    let state: TrailCardState
    let isStale: Bool

    public init(tripName: String, state: TrailCardState, isStale: Bool = false) {
        self.tripName = tripName
        self.state = state
        self.isStale = isStale
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PathAheadView(path: state.path, lineColour: state.status.colour)
                .frame(width: 92, height: 104)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: status.symbol)
                    Text(status.text)
                    if let detail = state.statusDetail { Text("· " + detail) }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(state.status.colour)
                .lineLimit(1)
                Text(state.title)
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let next = state.next {
                    Label {
                        Text(next).lineLimit(1)
                    } icon: {
                        Image(systemName: state.nextSymbol ?? "flag.checkered")
                    }
                    .font(.subheadline)
                }
                if let daylight = state.daylight {
                    Text(daylight)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(daylightColour)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if isStale {
                    Text("Not updating — open the app")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var daylightColour: Color {
        switch state.daylightLevel {
        case 2: .red
        case 1: .orange
        default: .secondary
        }
    }

    private var status: (text: String, symbol: String) {
        switch state.status {
        case .onRoute: ("On route", "checkmark.circle.fill")
        case .approaching: ("Heading to the route", "arrow.up.forward.circle")
        case .offRoute: ("Off route", "exclamationmark.triangle.fill")
        case .wrongWay: ("Walking against the route", "arrow.uturn.backward.circle.fill")
        case .weakGPS: ("Weak GPS", "location.slash")
        case .paused: ("Paused", "pause.circle.fill")
        case .arrived: ("Arrived", "flag.checkered")
        case .acquiring: ("Waiting for GPS", "location")
        }
    }
}

extension TrailCardState.Status {
    /// The colour the card gives this status, for the Dynamic Island as well.
    public var colour: Color {
        switch self {
        case .onRoute, .arrived: TrailCardColours.brand
        case .approaching: .blue
        case .offRoute: .red
        case .wrongWay, .weakGPS: .orange
        case .paused, .acquiring: .secondary
        }
    }
}

enum TrailCardColours {
    /// A lighter shade of the app's forest green: the card sits on a dark lock
    /// screen, where the app's own green all but disappears.
    static let brand = Color(red: 0x3f / 255, green: 0xa8 / 255, blue: 0x76 / 255)
}

/// The route ahead, the walker, and the next stop, in a small square.
public struct PathAheadView: View {
    let path: PathAhead?
    let lineColour: Color

    public init(path: PathAhead?, lineColour: Color) {
        self.path = path
        self.lineColour = lineColour
    }

    public var body: some View {
        Canvas { context, size in
            guard let path, path.points.count >= 2 else { return }
            var all = path.points + [path.walker]
            if let stop = path.stop { all.append(stop) }
            let minX = Double(all.map(\.x).min()!), maxX = Double(all.map(\.x).max()!)
            let minY = Double(all.map(\.y).min()!), maxY = Double(all.map(\.y).max()!)
            let inset = 9.0
            // One scale both ways, so a bend keeps its true angle; and never
            // closer than 500 m to the full height, so a short straight does
            // not look like a long one.
            let spanM = max(maxX - minX, maxY - minY, PathAhead.aheadM * 0.8)
            let scale = (min(size.width, size.height) - 2 * inset) / spanM
            let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
            func screen(_ p: PathAhead.Point) -> CGPoint {
                CGPoint(x: size.width / 2 + (Double(p.x) - midX) * scale,
                        y: size.height / 2 - (Double(p.y) - midY) * scale)
            }

            var line = Path()
            line.move(to: screen(path.points[0]))
            for p in path.points.dropFirst() { line.addLine(to: screen(p)) }
            context.stroke(line, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            context.stroke(line, with: .color(lineColour),
                           style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))

            if let stop = path.stop {
                let at = screen(stop)
                context.fill(Path(ellipseIn: CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)),
                             with: .color(.white))
                context.stroke(Path(ellipseIn: CGRect(x: at.x - 5, y: at.y - 5, width: 10, height: 10)),
                               with: .color(.black), lineWidth: 2)
            }

            // The walker: an arrow pointing the way the route runs, which is up.
            let at = screen(path.walker)
            var arrow = Path()
            arrow.move(to: CGPoint(x: at.x, y: at.y - 8))
            arrow.addLine(to: CGPoint(x: at.x + 6, y: at.y + 6))
            arrow.addLine(to: CGPoint(x: at.x, y: at.y + 3))
            arrow.addLine(to: CGPoint(x: at.x - 6, y: at.y + 6))
            arrow.closeSubpath()
            context.fill(arrow, with: .color(.blue))
            context.stroke(arrow, with: .color(.white), lineWidth: 1.5)
        }
    }
}
#endif
