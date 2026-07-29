import SwiftUI
import TripCore

/// The draggable information panel over the map.
///
/// Everything except the live readouts lives here, because the map is the
/// screen: covering it to read a profile defeats the reason for looking. The
/// panel therefore rests as a handle and a single row of numbers, and only
/// takes the screen when it is deliberately pulled up.
struct TrailInfoPanel: View {
    enum Tab: String, CaseIterable {
        case profile = "Profile"
        case stops = "Stops"
    }

    enum Detent {
        /// A bare grab strip. Even the tab titles are given back to the map —
        /// at rest this panel should cost almost nothing.
        case collapsed
        /// Enough for the profile or three or four stops.
        case medium
        /// For reading a long checkpoint note.
        case expanded

        func height(in total: CGFloat) -> CGFloat {
            switch self {
            case .collapsed: 26
            case .medium: min(320, total * 0.42)
            case .expanded: total * 0.82
            }
        }
    }

    let package: TripPackage
    var routeDistanceM: Double?
    /// A checkpoint tapped on the map opens the panel on its note.
    @Binding var selected: TripPackage.Checkpoint?
    @Binding var detent: Detent
    @Binding var tab: Tab
    /// The walking day the whole screen is narrowed to, by `index`. Nil is the
    /// whole trip.
    @Binding var dayScope: Int?
    /// Kinds to show. Empty means all, matching the web planner's chips.
    @Binding var kindFilter: Set<CheckpointKind>

    @State private var dragOffset: CGFloat = 0
    @State private var pointA: Double?
    @State private var pointB: Double?
    @State private var movingPoint: ProfilePoint = .a
    @State private var profileZoom: Double = 1
    @State private var snapsToStops = false
    #if DEBUG
    /// Lets a screenshot run put a finger on the chart.
    private let debugScrub = NotificationCenter.default.publisher(
        for: Notification.Name("ULPDebugScrub")
    )
    #endif

    var body: some View {
        GeometryReader { geometry in
            let height = detent.height(in: geometry.size.height)

            VStack(spacing: 0) {
                handle
                if detent != .collapsed {
                    dayBar
                    Divider()
                    tabBar
                    Divider()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(height: max(26, height - dragOffset), alignment: .top)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 8, y: -2)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .gesture(dragGesture(total: geometry.size.height))
            #if DEBUG
            .onReceive(debugScrub) { note in
                guard let fraction = note.userInfo?["fraction"] as? Double else { return }
                let range = scopeRange ?? 0...RouteProfiles.profile(for: package).totalM
                if let extra = note.userInfo?["zoom"] as? Double { profileZoom = extra }
                if let snap = note.userInfo?["snap"] as? Bool { snapsToStops = snap }
                pointA = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                pointB = range.lowerBound + min(1, fraction + 0.28)
                    * (range.upperBound - range.lowerBound)
            }
            #endif
        }
    }

    // MARK: - Chrome

    private var handle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 38, height: 5)
            .padding(.top, 9)
            .padding(.bottom, 9)
            // The whole strip is draggable, not just the bar: a 5 pt target is
            // not something to find with a gloved thumb.
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    /// The day picker, and that day's headline numbers.
    ///
    /// One row above the tabs because the choice governs both of them and the
    /// map behind. The numbers on the right are the reason to look: distance,
    /// climb and the Alpine club's time for the day, which is the answer to
    /// "what is tomorrow" without opening anything else.
    private var dayBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    dayScope = nil
                } label: {
                    Label("Whole trip", systemImage: dayScope == nil ? "checkmark" : "")
                }
                ForEach(walkingDays, id: \.day.index) { entry in
                    Button {
                        dayScope = entry.day.index
                    } label: {
                        Label(
                            "Day \(entry.number) · \(entry.day.endName)",
                            systemImage: dayScope == entry.day.index ? "checkmark" : ""
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(scopeTitle).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Color.brand)
            }

            Spacer(minLength: 4)

            if let summary = scopeSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Color.subtle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var walkingDays: [(day: TripPackage.Day, number: Int)] {
        Itinerary.combined(package).compactMap { entry in
            guard case .walking(let day, let number) = entry else { return nil }
            return (day, number)
        }
    }

    private var scopedDay: TripPackage.Day? {
        dayScope.flatMap { index in package.itinerary.first { $0.index == index } }
    }

    /// The route distances the chosen day covers, or nil for the whole trip.
    var scopeRange: ClosedRange<Double>? {
        guard let day = scopedDay else { return nil }
        return Double(day.startRouteM)...Double(day.endRouteM)
    }

    private var scopeTitle: String {
        guard let day = scopedDay else { return "Whole trip" }
        let number = walkingDays.first { $0.day.index == day.index }?.number ?? day.index
        return "Day \(number)"
    }

    private var scopeSummary: String? {
        guard let range = scopeRange else { return nil }
        let leg = RouteProfiles.profile(for: package)
            .leg(fromRouteM: range.lowerBound, toRouteM: range.upperBound)
        var parts = [String(format: "%.1f km", leg.distanceM / 1000)]
        if let ascent = leg.ascentM { parts.append("↑\(Int(ascent.rounded())) m") }
        if let duration = leg.duration {
            let minutes = Int((duration / 60).rounded())
            parts.append("\(minutes / 60) h \(minutes % 60)")
        }
        return parts.joined(separator: " · ")
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button {
                    tab = item
                    if detent == .collapsed { detent = .medium }
                    if item != .stops { selected = nil }
                } label: {
                    Text(item.rawValue)
                        .font(.subheadline.weight(tab == item ? .semibold : .regular))
                        .foregroundStyle(tab == item ? Color.primary : Color.subtle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(tab == item ? Color.brand : .clear)
                        .frame(height: 2)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .profile:
            VStack(spacing: 0) {
                // A fixed height, not the whole panel. Pulled up to read a
                // note, the chart used to stretch with it — 164 km of route
                // rendered a hand tall, which is not a profile of anything.
                // The room the panel gains goes to what is under the finger
                // instead.
                ElevationProfileView(
                    package: package,
                    routeDistanceM: routeDistanceM,
                    pointA: $pointA,
                    pointB: $pointB,
                    moving: $movingPoint,
                    zoom: $profileZoom,
                    snapsToCheckpoints: snapsToStops,
                    range: scopeRange
                )
                .frame(height: 168)
                .padding(.horizontal, 12)
                .padding(.top, 10)

                ProfileReadout(
                    package: package,
                    pointA: pointA,
                    pointB: pointB,
                    moving: $movingPoint,
                    snapsToStops: $snapsToStops,
                    zoom: $profileZoom,
                    from: routeDistanceM,
                    onClear: {
                        pointA = nil
                        pointB = nil
                        movingPoint = .a
                        profileZoom = 1
                    }
                )
                .padding(.horizontal, 12)
                .padding(.top, 10)

                Spacer(minLength: 0)
            }
        case .stops:
            stopsList
        }
    }

    // MARK: - Stops

    private var stopsList: some View {
        VStack(spacing: 0) {
            kindFilterBar
            Divider()
            // The detail opens under the row it belongs to, not at the top of
            // the list. Detached, reading a stop meant scrolling down to find
            // it, tapping, and scrolling all the way back up to read the
            // answer — then back down again for the next one.
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleCheckpoints, id: \.id) { checkpoint in
                            Button {
                                // Tapping the open stop closes it, so the list
                                // can be collapsed back without hunting for the
                                // small ✕.
                                selected = selected?.id == checkpoint.id ? nil : checkpoint
                                if selected != nil { detent = .expanded }
                            } label: {
                                CheckpointRow(
                                    checkpoint: checkpoint,
                                    from: routeDistanceM,
                                    isOpen: selected?.id == checkpoint.id
                                )
                            }
                            .buttonStyle(.plain)

                            if selected?.id == checkpoint.id {
                                CheckpointDetail(
                                    checkpoint: checkpoint, package: package, from: routeDistanceM
                                )
                            }
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                // A tap on the map picks a stop the list may have scrolled far
                // past, so the list follows the map rather than leaving the
                // walker to find it.
                .onChange(of: selected?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        scroller.scrollTo(id, anchor: .top)
                    }
                }
            }
        }
    }

    /// Additive chips, the same rule as the web planner: each toggles its own
    /// kind and an empty selection means All. Fifty-six stops is a lot to read
    /// when the only question is "where is the next water".
    private var kindFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // The accent, not grey: white on secondary is barely legible, and
                // "All" is the state the filter spends most of its life in.
                chip(label: "All", active: kindFilter.isEmpty, tint: .brand) {
                    kindFilter.removeAll()
                }
                ForEach(presentKinds, id: \.self) { kind in
                    chip(
                        label: kind.label,
                        active: kindFilter.contains(kind),
                        tint: ElevationProfileView.tint(for: kind),
                        symbol: kind.symbolName
                    ) {
                        if kindFilter.contains(kind) { kindFilter.remove(kind) }
                        else { kindFilter.insert(kind) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    /// Only kinds this trip actually uses — offering a "Ferry" filter for a
    /// route with no ferries is noise.
    private var presentKinds: [CheckpointKind] {
        let used = Set(package.checkpoints.map(\.checkpointKind))
        return CheckpointKind.allCases.filter { used.contains($0) }
    }

    private func chip(
        label: String,
        active: Bool,
        tint: Color,
        symbol: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
                Text(label).font(.caption.weight(active ? .semibold : .regular))
            }
            .foregroundStyle(active ? .white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(active ? tint : Color.primary.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
    }

    /// Ahead of the walker while recording, otherwise the whole trip. Before
    /// starting, the point is to read the plan; while walking, what is behind
    /// is not what the next decision is about.
    private var visibleCheckpoints: [TripPackage.Checkpoint] {
        // The day, if one is chosen, narrows the list before anything else —
        // and it replaces the "only what is ahead" rule, because a day being
        // read as a preview is not a day being walked.
        let inScope = scopeRange.map { range in
            package.checkpoints.filter { range.contains(Double($0.routeDistanceM)) }
        } ?? package.checkpoints
        let matching = kindFilter.isEmpty
            ? inScope
            : inScope.filter { kindFilter.contains($0.checkpointKind) }
        if scopeRange != nil {
            guard let selected, !matching.contains(where: { $0.id == selected.id })
            else { return matching }
            return (matching + [selected]).sorted { $0.routeDistanceM < $1.routeDistanceM }
        }
        let listed: [TripPackage.Checkpoint]
        if let routeDistanceM {
            let ahead = matching.filter { Double($0.routeDistanceM) > routeDistanceM }
            listed = ahead.isEmpty ? matching : ahead
        } else {
            listed = matching
        }
        // The open stop is never filtered away. Now that its detail lives
        // inside the list, a filter that excluded it would take the thing being
        // read off the screen — and a stop tapped on the map is often one the
        // current filter does not cover.
        guard let selected, !listed.contains(where: { $0.id == selected.id }) else { return listed }
        return (listed + [selected]).sorted { $0.routeDistanceM < $1.routeDistanceM }
    }

    // MARK: - Drag

    private func dragGesture(total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in dragOffset = value.translation.height }
            .onEnded { value in
                let velocity = value.predictedEndTranslation.height
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    detent = Self.nextDetent(from: detent, drag: velocity)
                    dragOffset = 0
                }
            }
    }

    /// One step per gesture. Snapping straight from collapsed to full screen on
    /// a fast flick is disorienting when the map underneath is what orients you.
    static func nextDetent(from current: Detent, drag: CGFloat) -> Detent {
        let up = drag < -40
        let down = drag > 40
        switch current {
        case .collapsed: return up ? .medium : .collapsed
        case .medium: return up ? .expanded : (down ? .collapsed : .medium)
        case .expanded: return down ? .medium : .expanded
        }
    }
}

// MARK: - Rows

private struct CheckpointRow: View {
    let checkpoint: TripPackage.Checkpoint
    let from: Double?
    var isOpen = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: checkpoint.checkpointKind.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(ElevationProfileView.tint(for: checkpoint.checkpointKind)))

            VStack(alignment: .leading, spacing: 1) {
                Text(checkpoint.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(checkpoint.checkpointKind.label)
                    if let ele = checkpoint.ele { Text("· \(ele) m") }
                    // A note exists and is worth opening for — some of these
                    // are the reason the checkpoint was made at all.
                    if !checkpoint.note.isEmpty {
                        Image(systemName: "text.alignleft").font(.caption2)
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color.subtle)
            }
            Spacer(minLength: 8)
            if let from {
                let distance = Double(checkpoint.routeDistanceM) - from
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.2f km", distance / 1000))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Text(estimate(distance)).font(.caption2).foregroundStyle(Color.subtle)
                }
            } else {
                Text(String(format: "%.1f km", Double(checkpoint.routeDistanceM) / 1000))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.subtle)
            }

            // Says the row opens, and which one is open. Without it a tap
            // looks like it did nothing until the eye finds the card that
            // appeared below.
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.subtle)
                .rotationEffect(.degrees(isOpen ? 0 : -90))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private func estimate(_ metres: Double) -> String {
        let minutes = Int((metres / 1000 / 4.0 * 60).rounded())
        return minutes < 60 ? "~\(minutes) min" : "~\(minutes / 60) h \(minutes % 60) min"
    }
}

/// The opened checkpoint: everything the planner wrote about it.
private struct CheckpointDetail: View {
    let checkpoint: TripPackage.Checkpoint
    let package: TripPackage
    let from: Double?

    /// What it takes to get there from where the walker is now — or, before the
    /// walk starts, from the beginning of the route.
    private var leg: RouteProfile.Leg {
        RouteProfiles.profile(for: package)
            .leg(fromRouteM: from ?? 0, toRouteM: Double(checkpoint.routeDistanceM))
    }

    var body: some View {
        // No name, no icon, no close button: the row this card opens under
        // carries all three, and repeating them put "Bellevue" on the screen
        // twice in a row. What is left is only what the row could not say.
        VStack(alignment: .leading, spacing: 10) {
            legRow

            if checkpoint.note.isEmpty {
                Text("No note for this stop.")
                    .font(.footnote)
                    .foregroundStyle(Color.subtle)
            } else {
                // Notes are Markdown in the planner. Inline-only interpretation
                // keeps the author's line breaks, which matters when the note
                // is really a checklist — booking details, water carry, a
                // crossing that is out after rain.
                Text(note)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
    }

    /// Distance, time and climb between here and the stop.
    ///
    /// The three together or none of them: on a mountain route the distance
    /// alone is close to meaningless — the same 4 km is an hour along a valley
    /// and three hours over a col — and it is exactly this row that answers
    /// whether there is time to reach the next refuge or whether the answer is
    /// to stop where you are.
    private var legRow: some View {
        VStack(spacing: 4) {
            HStack(alignment: .top, spacing: 0) {
                legStat("Distance", Self.distance(leg.distanceM))
                legDivider
                legStat("Time", Self.duration(leg.duration))
                legDivider
                legStat("Climb", Self.climb(leg))
            }
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))

            // Below the numbers rather than tucked into a corner of them: put
            // anywhere inside the box it lands on top of the climb figure,
            // which is the one number that runs long.
            Text(origin)
                .font(.caption2)
                .foregroundStyle(Color.subtle)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Where the numbers are measured from. Never left implicit: "4.2 km" means
    /// two different things before and after the walk starts, and a stop behind
    /// you is a different answer again.
    private var origin: String {
        if leg.isBehind { return "walking back from here" }
        return from == nil ? "from the start of the route" : "from where you are"
    }

    private func legStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Color.subtle)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var legDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(width: 1, height: 26)
    }

    static func distance(_ metres: Double) -> String {
        metres < 1000
            ? "\(Int(metres.rounded())) m"
            : String(format: "%.1f km", metres / 1000)
    }

    /// Hours and minutes, never decimal hours — "1 h 45" is a time a walker can
    /// hold against a watch; "1.75 h" is arithmetic to do at a col.
    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min" }
        return String(format: "%d h %02d", minutes / 60, minutes % 60)
    }

    /// Ascent over descent, stacked. Both matter and for different reasons —
    /// the climb decides the time, the descent decides the knees.
    static func climb(_ leg: RouteProfile.Leg) -> String {
        guard let ascent = leg.ascentM, let descent = leg.descentM else { return "—" }
        return "↑\(Int(ascent.rounded())) ↓\(Int(descent.rounded()))"
    }


    private var note: AttributedString {
        (try? AttributedString(
            markdown: checkpoint.note,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(checkpoint.note)
    }
}

/// One `RouteProfile` per trip, kept alive between views.
///
/// Building it walks all 8,561 points of the route. That is nothing once and
/// far too much on every SwiftUI redraw, and a detail card redraws whenever the
/// walker moves.
enum RouteProfiles {
    static func profile(for package: TripPackage) -> RouteProfile {
        let key = "\(package.tripId)#\(package.revision)"
        if let cached = cache[key] { return cached }
        let profile = RouteProfile(package: package)
        cache[key] = profile
        return profile
    }

    private nonisolated(unsafe) static var cache: [String: RouteProfile] = [:]
}

/// What is at the point being touched, and what lies between two of them.
///
/// The profile answers "how hard" for a whole stretch. One point answers it for
/// one place; two answer it for the stretch between them, which is the question
/// behind most decisions on a walk — whether to push on to the next col before
/// dark, whether the climb after lunch is the one that hurts.
private struct ProfileReadout: View {
    let package: TripPackage
    let pointA: Double?
    let pointB: Double?
    @Binding var moving: ProfilePoint
    @Binding var snapsToStops: Bool
    @Binding var zoom: Double
    let from: Double?
    let onClear: () -> Void

    private var profile: RouteProfile { RouteProfiles.profile(for: package) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pointA {
                point(pointA)
                if let pointB { between(pointA, pointB) }
                controls
            } else {
                Text("Touch the profile to read a point.")
                    .font(.caption)
                    .foregroundStyle(Color.subtle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - One point

    private func point(_ routeM: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 0) {
                // Labelled, because "−22%" on its own is a number nobody can
                // name. It is the slope at that spot, and it reads as a
                // question until it says so.
                stat("From start", String(format: "%.1f km", routeM / 1000))
                stat("Height", profile.elevation(atRouteM: routeM).map { "\(Int($0.rounded())) m" } ?? "—")
                stat(
                    "Gradient",
                    profile.gradient(atRouteM: routeM).map { String(format: "%+.0f%%", $0) } ?? "—",
                    warn: (profile.gradient(atRouteM: routeM) ?? 0) > 8
                )
            }

            if let next = package.checkpoints.first(where: { Double($0.routeDistanceM) > routeM }) {
                caption(String(
                    format: "Next: %@ · %.1f km on",
                    next.displayName, (Double(next.routeDistanceM) - routeM) / 1000
                ))
            }

            // Only while recording, because "from here" needs a here.
            if let from {
                caption(leg("From you", profile.leg(fromRouteM: from, toRouteM: routeM)))
            }
        }
    }

    // MARK: - Two points

    private func between(_ a: Double, _ b: Double) -> some View {
        // Always earlier point to later one, whichever was placed first: a
        // stretch of route has a direction and the walker is going one way
        // along it, so a negative climb here would be a different walk.
        let leg = profile.leg(fromRouteM: min(a, b), toRouteM: max(a, b))
        return caption(self.leg("A → B", leg))
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.primary)
    }

    private func leg(_ prefix: String, _ leg: RouteProfile.Leg) -> String {
        var parts = [String(format: "%.1f km", leg.distanceM / 1000)]
        if let ascent = leg.ascentM, let descent = leg.descentM {
            parts.append("↑\(Int(ascent.rounded())) ↓\(Int(descent.rounded())) m")
        }
        if let duration = leg.duration {
            let minutes = Int((duration / 60).rounded())
            parts.append(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60)" : "\(minutes) min")
        }
        let direction = leg.isBehind ? " (back)" : ""
        return "\(prefix)\(direction): " + parts.joined(separator: " · ")
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            chip("A", active: moving == .a, tint: .brand) { moving = .a }
            chip(pointB == nil ? "Add B" : "B", active: moving == .b, tint: .red) { moving = .b }
            // Next to the points it governs, because that is the only place
            // anyone would look for it. On, a point lands on the nearest stop:
            // a leg between two places is a number worth quoting, while one
            // between wherever two fingers landed is different every time.
            chip("Stops", active: snapsToStops, tint: .brand) { snapsToStops.toggle() }
            Spacer(minLength: 4)
            if zoom > 1.01 {
                Text(String(format: "%.0f×", zoom))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.subtle)
            }
            Button("Clear", action: onClear)
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.brand)
        }
    }

    /// Which point the next drag moves. Two taps to measure a stretch: pick B,
    /// then drag — rather than a mode nobody would find.
    private func chip(
        _ title: String, active: Bool, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(active ? tint : Color.primary.opacity(0.07)))
                .foregroundStyle(active ? .white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func stat(_ title: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(Color.subtle)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(warn ? Color.orange : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Color.subtle)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
