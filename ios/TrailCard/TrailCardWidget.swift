import ActivityKit
import SwiftUI
import TripCore
import WidgetKit

/// The lock-screen card for a walk being recorded. Everything it shows is
/// decided in the app (`TrailCardState`) and drawn by `TrailCardView`, shared
/// through TripCore; this extension only hands the two to the system.
@main
struct TrailCardBundle: WidgetBundle {
    var body: some Widget {
        TrailCardWidget()
    }
}

struct TrailCardWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrailCardAttributes.self) { context in
            // A dark card in light mode and dark alike: the line and the
            // figures are drawn for it, and it reads the same in any wallpaper.
            TrailCardView(tripName: context.attributes.tripName, state: context.state, isStale: context.isStale)
                .environment(\.colorScheme, .dark)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PathAheadView(path: context.state.path, lineColour: TrailCardState.Status.onRoute.colour)
                        .frame(width: 64, height: 72)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let short = context.state.nextShort {
                        Text(short).font(.headline.monospacedDigit())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.subheadline.weight(.semibold))
                        if let next = context.state.next {
                            Text(next).font(.caption).lineLimit(1)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "figure.hiking")
                    .foregroundStyle(context.state.status.colour)
            } compactTrailing: {
                Text(context.state.nextShort ?? "")
                    .font(.caption.monospacedDigit())
            } minimal: {
                Image(systemName: "figure.hiking")
                    .foregroundStyle(context.state.status.colour)
            }
        }
    }
}
