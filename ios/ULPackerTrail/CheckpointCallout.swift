import SwiftUI
import TripCore

/// The bubble that appears at a checkpoint when its pin is tapped.
///
/// On the map rather than only in the panel, because the question a tap asks is
/// "what is *this* one" — and answering it somewhere else makes the walker look
/// away from the thing they just pointed at. Every hiking map does this; it is
/// the map equivalent of a label you can ask for.
///
/// Deliberately small and self-contained: name, what kind of place it is, how
/// far off it is, and the planner's note. Anything longer belongs in the panel,
/// which the "Details" button opens.
struct CheckpointCallout: View {
    let checkpoint: TripPackage.Checkpoint
    /// Where the pin is on screen, so the bubble can point at it.
    let anchor: CGPoint
    let from: Double?
    let onOpenDetails: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let width = min(300.0, size.width - 24)
            let height = estimatedHeight(width: width)
            let inset = 10.0

            // Clamp inside the map on both axes. The first version only
            // clamped x and pushed y by a fixed offset, so a pin near the top
            // put the bubble half off the screen and over the title bar.
            let preferAbove = anchor.y - height - 18 > inset
            let rawY = preferAbove ? anchor.y - height / 2 - 18 : anchor.y + height / 2 + 18
            let x = min(max(width / 2 + inset, anchor.x), size.width - width / 2 - inset)
            let y = min(max(height / 2 + inset, rawY), size.height - height / 2 - inset)

            card
                .frame(width: width)
                .position(x: x, y: y)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
    }

    /// Rough height, used only for clamping. Being a little wrong just shifts
    /// the bubble a few points; being unclamped puts it off the screen.
    private func estimatedHeight(width: CGFloat) -> CGFloat {
        let base: CGFloat = 92
        guard !checkpoint.note.isEmpty else { return base }
        let charsPerLine = max(1, Int((width - 24) / 6.5))
        let lines = CGFloat((checkpoint.note.count / charsPerLine) + 1)
        return base + min(lines, 4) * 16
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: checkpoint.checkpointKind.symbolName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle().fill(ElevationProfileView.tint(for: checkpoint.checkpointKind))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(checkpoint.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Color.subtle)
                }

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.subtle)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !checkpoint.note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onOpenDetails) {
                Text("Details")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.indigo)
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }

    private var subtitle: String {
        var parts = [checkpoint.checkpointKind.label]
        if let ele = checkpoint.ele { parts.append("\(ele) m") }
        if let from {
            let distance = Double(checkpoint.routeDistanceM) - from
            // "2.4 km ahead" is the useful form while walking; the absolute
            // route position only helps when planning.
            parts.append(
                distance >= 0
                    ? String(format: "%.2f km ahead", distance / 1000)
                    : String(format: "%.2f km behind", -distance / 1000)
            )
        } else {
            parts.append(String(format: "km %.1f", Double(checkpoint.routeDistanceM) / 1000))
        }
        return parts.joined(separator: " · ")
    }

    /// Notes are Markdown in the planner; inline-only keeps the author's line
    /// breaks without pulling in block layout the bubble has no room for.
    private var note: AttributedString {
        (try? AttributedString(
            markdown: checkpoint.note,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(checkpoint.note)
    }
}
