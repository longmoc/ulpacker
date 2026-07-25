import SwiftUI
import TripCore

/// M1's whole UI: prove a real TripPackage decodes, verifies and reads sensibly
/// on the device. Deliberately plain — the navigation screen that matters comes
/// after Core Location is known to work, not before.
struct TripListView: View {
    let library: TripLibrary

    var body: some View {
        NavigationStack {
            Group {
                switch library.state {
                case .loading:
                    ProgressView()
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Could not load a trip", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                case .loaded(let packages):
                    List(packages, id: \.tripId) { package in
                        NavigationLink {
                            TripDetailView(package: package)
                        } label: {
                            TripRow(package: package)
                        }
                    }
                }
            }
            .navigationTitle("Trips")
        }
    }
}

private struct TripRow: View {
    let package: TripPackage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(package.trip.name).font(.headline)
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // Built as a plain String: interpolating into `Text` directly would resolve
    // to LocalizedStringKey, which cannot be concatenated.
    private var summary: String {
        [
            String(format: "%.1f km", package.distanceKM),
            "\(package.itinerary.count) days",
            "\(package.checkpoints.count) checkpoints"
        ].joined(separator: " · ")
    }
}

struct TripDetailView: View {
    let package: TripPackage

    var body: some View {
        List {
            Section("Route") {
                LabeledContent("Distance", value: String(format: "%.1f km", package.distanceKM))
                if let ascent = package.plannedRoute.stats.ascentM {
                    LabeledContent("Ascent", value: "\(ascent) m")
                }
                if let descent = package.plannedRoute.stats.descentM {
                    LabeledContent("Descent", value: "\(descent) m")
                }
                LabeledContent("Points", value: "\(package.plannedRoute.stats.pointCount)")
                LabeledContent("Segments", value: "\(package.plannedRoute.stats.segmentCount)")
            }

            Section {
                NavigationLink {
                    TrailView(package: package)
                } label: {
                    Label("Start trail", systemImage: "figure.hiking")
                }
            }

            Section("Itinerary") {
                ForEach(package.itinerary, id: \.index) { day in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Day \(day.index): \(day.startName) → \(day.endName)")
                            .font(.subheadline.weight(.medium))
                        Text(dayDetail(day))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("Overnight stops") {
                ForEach(package.overnightCheckpoints, id: \.id) { checkpoint in
                    LabeledContent(
                        checkpoint.name,
                        value: String(format: "%.1f km", Double(checkpoint.routeDistanceM) / 1000)
                    )
                }
            }

            // Shown because it is the thing M1 is really testing: this number
            // was produced independently by the JS planner and recomputed here.
            Section("Package") {
                LabeledContent("Revision", value: "\(package.revision)")
                LabeledContent("Content hash", value: package.contentHash)
                    .font(.caption.monospaced())
            }
        }
        .navigationTitle(package.trip.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func dayDetail(_ day: TripPackage.Day) -> String {
        var parts = [String(format: "%.1f km", Double(day.distanceM) / 1000)]
        if let ascent = day.ascentM { parts.append("↑\(ascent) m") }
        if let descent = day.descentM { parts.append("↓\(descent) m") }
        return parts.joined(separator: " · ")
    }
}
