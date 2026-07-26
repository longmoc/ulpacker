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
    /// Kinds to show. Empty means all, matching the web planner's chips.
    @Binding var kindFilter: Set<CheckpointKind>

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let height = detent.height(in: geometry.size.height)

            VStack(spacing: 0) {
                handle
                if detent != .collapsed {
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
                        .fill(tab == item ? Color.indigo : .clear)
                        .frame(height: 2)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .profile:
            ElevationProfileView(package: package, routeDistanceM: routeDistanceM)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        case .stops:
            stopsList
        }
    }

    // MARK: - Stops

    private var stopsList: some View {
        VStack(spacing: 0) {
            kindFilterBar
            Divider()
            ScrollView {
            LazyVStack(spacing: 0) {
                if let selected {
                    CheckpointDetail(
                        checkpoint: selected, package: package, from: routeDistanceM
                    ) {
                        self.selected = nil
                    }
                    Divider()
                }

                ForEach(visibleCheckpoints, id: \.id) { checkpoint in
                    Button {
                        selected = checkpoint
                        detent = .expanded
                    } label: {
                        CheckpointRow(checkpoint: checkpoint, from: routeDistanceM)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 54)
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
                // Indigo, not grey: white on secondary is barely legible, and
                // "All" is the state the filter spends most of its life in.
                chip(label: "All", active: kindFilter.isEmpty, tint: .indigo) {
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
        let matching = kindFilter.isEmpty
            ? package.checkpoints
            : package.checkpoints.filter { kindFilter.contains($0.checkpointKind) }
        guard let routeDistanceM else { return matching }
        let ahead = matching.filter { Double($0.routeDistanceM) > routeDistanceM }
        return ahead.isEmpty ? matching : ahead
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
    let onClose: () -> Void

    /// What it takes to get there from where the walker is now — or, before the
    /// walk starts, from the beginning of the route.
    private var leg: RouteProfile.Leg {
        RouteProfiles.profile(for: package)
            .leg(fromRouteM: from ?? 0, toRouteM: Double(checkpoint.routeDistanceM))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: checkpoint.checkpointKind.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(ElevationProfileView.tint(for: checkpoint.checkpointKind))
                    )

                // Explicit width and layout priority: without them the title and
                // the close button squeezed the subtitle out of existence
                // entirely, which is how this card first shipped.
                VStack(alignment: .leading, spacing: 2) {
                    Text(checkpoint.displayName)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.subtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.subtle)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

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

    private var subtitle: String {
        var parts = [checkpoint.checkpointKind.label]
        if let ele = checkpoint.ele { parts.append("\(ele) m") }
        parts.append(String(format: "km %.1f", Double(checkpoint.routeDistanceM) / 1000))
        if let from {
            let distance = Double(checkpoint.routeDistanceM) - from
            if distance > 0 { parts.append(String(format: "%.2f km ahead", distance / 1000)) }
        }
        return parts.joined(separator: " \u{00B7} ")
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

extension Color {
    /// Secondary text that survives being drawn on a material.
    ///
    /// `.secondary` — as a shape style or as `Color.secondary`, they are the
    /// same thing — is hierarchical, and over a material SwiftUI renders it as
    /// vibrancy rather than as grey ink. Vibrancy takes its contrast from
    /// whatever lies *behind* the material, and behind this panel is the map:
    /// on a pale valley floor it is nearly white, and every subtitle, stat
    /// heading and close button dissolved into it while the titles beside them
    /// stayed black. The smaller the type the worse it got, which is exactly
    /// backwards.
    ///
    /// A plain colour is not reinterpreted, so it stays legible whatever the
    /// map is doing underneath.
    static let subtle = Color(uiColor: .secondaryLabel)
}
