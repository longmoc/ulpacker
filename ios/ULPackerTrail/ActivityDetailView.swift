import CoreLocation
import SwiftUI
import TripCore

/// One recorded walk: where it went, when, and the way to get it off the phone.
///
/// The map draws the track actually walked over the planned route, and a
/// scrubber moves a marker along it in time — where was I at 10:24, how far had
/// I gone by then. That is what turns a list of numbers into something a walker
/// can check against their memory of the day, and what made the field review of
/// the navigation possible without a laptop on the trail.
///
/// The export is the other half: until it existed a finished walk lived only in
/// the app's container, reachable by cable and Finder. A `ShareLink` over a GPX
/// file is the door out.
struct ActivityDetailView: View {
    let package: TripPackage
    let activity: ActivityPackage
    private let replay: Replay
    /// Index into `replay.fixes` of the point the marker sits on. Starts at the
    /// end — "where the walk finished" is the first thing worth seeing.
    @State private var scrub: Double
    /// The exported file, written once on appear. `ShareLink` shares a real file
    /// so the sheet offers a named `.gpx`, not a blob of text.
    @State private var gpxURL: URL?

    init(package: TripPackage, activity: ActivityPackage) {
        self.package = package
        self.activity = activity
        let replay = Replay(activity)
        self.replay = replay
        _scrub = State(initialValue: Double(max(0, replay.fixes.count - 1)))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !replay.fixes.isEmpty {
                RouteMapView(
                    package: package,
                    position: replay.coordinate(at: index),
                    courseDegrees: replay.course(at: index),
                    followMode: .free,
                    recordedTrack: replay.segments
                )
                .frame(height: 320)
                scrubber
                Divider()
            }
            details
        }
        .navigationTitle("Walk")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if gpxURL == nil { gpxURL = writeGPX() } }
    }

    private var index: Int {
        min(max(0, Int(scrub.rounded())), max(0, replay.fixes.count - 1))
    }

    /// Clock time, time since the start, and distance walked by then — the three
    /// things a walker uses to place a moment of the day.
    private var scrubber: some View {
        VStack(spacing: 6) {
            HStack {
                Label(replay.fixes[index].t.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                Spacer()
                Text(Self.elapsed(replay.fixes[index].t.timeIntervalSince(activity.startedAt)))
                Spacer()
                Text(String(format: "%.2f km", replay.walkedM[index] / 1000))
            }
            .font(.footnote.monospacedDigit())
            .foregroundStyle(Color.subtle)

            if replay.fixes.count > 1 {
                Slider(value: $scrub, in: 0...Double(replay.fixes.count - 1), step: 1)
                    .tint(.orange)
                    .accessibilityLabel("Position along the walk")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
    }

    private static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "+%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "+%d:%02d", s / 60, s % 60)
    }

    private var details: some View {
        List {
            Section("Walk") {
                LabeledContent("Date", value: activity.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Walked", value: String(format: "%.1f km", Double(activity.stats.distanceM) / 1000))
                LabeledContent("Duration", value: duration)
                LabeledContent("Fixes", value: "\(activity.stats.fixCount)")
                if activity.diagnostics.rejectedFixCount > 0 {
                    LabeledContent("Poor fixes", value: "\(activity.diagnostics.rejectedFixCount)")
                }
                if activity.diagnostics.maxGapS >= 60 {
                    LabeledContent("Longest gap", value: "\(activity.diagnostics.maxGapS / 60) min")
                }
                if activity.diagnostics.recoveredFromCrash {
                    LabeledContent("Recovered", value: "after an interruption")
                }
            }

            if let power = activity.power, power.isReliable, let rate = power.percentPerHour {
                Section("Battery") {
                    LabeledContent("Drain", value: String(format: "%.1f%%/h", rate))
                    if power.backgroundReliable, let pocket = power.backgroundPercentPerHour {
                        LabeledContent("In pocket", value: String(format: "%.1f%%/h", pocket))
                    }
                    if power.maxThermal != "nominal" {
                        LabeledContent("Ran", value: power.maxThermal)
                    }
                }
            }

            Section {
                if let gpxURL {
                    ShareLink(item: gpxURL) {
                        Label("Export as GPX", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Preparing…", systemImage: "square.and.arrow.up")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("The track you actually walked, to save or share.")
            }
        }
    }

    private var duration: String {
        let minutes = activity.stats.durationS / 60
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// Write the GPX to a temp file named for the trip and the day, so the share
    /// sheet and whatever receives it show something a person recognises rather
    /// than a UUID.
    private func writeGPX() -> URL? {
        let stamp = activity.startedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let title = "\(package.trip.name) \(stamp)"
        let gpx = ActivityGPX.export(activity, name: title)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.safeName(title) + ".gpx")
        do {
            try gpx.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }

    /// A filename a filesystem will accept: no slashes, colons, or other
    /// separators that would split the name or be rejected.
    private static func safeName(_ text: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        return text.components(separatedBy: unsafe).joined(separator: "-")
    }
}

/// The walk prepared for drawing and scrubbing, built once per screen.
///
/// Only fixes good enough to navigate with are drawn — the same accuracy line
/// the matcher uses — so a 400 m reading under a roof does not draw a spike the
/// walker never made. The GPX export stays faithful to every fix; this is a
/// picture of where the walker was, not a record of every reading.
private struct Replay {
    let fixes: [ActivityPackage.Fix]
    let segments: [[CLLocationCoordinate2D]]
    /// Distance walked up to each fix, by the same rule as the saved total, so
    /// the scrubber at the last point reads exactly the walk's distance.
    let walkedM: [Double]

    init(_ activity: ActivityPackage) {
        let maxAccuracy = RouteMatcher.Configuration().maxAccuracyM
        let usable = activity.fixes
            .filter { $0.isUsable(maxAccuracyM: maxAccuracy) }
            .sorted { $0.t < $1.t }
        fixes = usable
        segments = ActivityGPX.segments(of: usable).map { segment in
            segment.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        }
        var total = 0.0
        var cumulative: [Double] = []
        for (i, fix) in usable.enumerated() {
            if i > 0 { total += WalkedDistance.step(from: usable[i - 1], to: fix) }
            cumulative.append(total)
        }
        walkedM = cumulative
    }

    func coordinate(at i: Int) -> CLLocationCoordinate2D? {
        guard fixes.indices.contains(i) else { return nil }
        return CLLocationCoordinate2D(latitude: fixes[i].lat, longitude: fixes[i].lng)
    }

    /// The receiver's course while moving, as the live screen uses it; a plain
    /// dot when standing still, where a course means nothing.
    func course(at i: Int) -> Double? {
        guard fixes.indices.contains(i),
              let speed = fixes[i].speed, speed >= WalkedDistance.stationarySpeedMPS,
              let bearing = fixes[i].bearing, bearing >= 0
        else { return nil }
        return bearing
    }
}
