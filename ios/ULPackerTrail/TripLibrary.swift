import Foundation
import Observation
import TripCore

/// Holds the trip packages this device knows about.
///
/// Trips come from `Documents/trips`, and nothing is bundled with the app. A
/// demo route used to ship inside it — the test fixture, in fact — which meant
/// the phone always listed a trip nobody was going to walk alongside the real
/// one, and the two were a tap apart on the way to the map.
///
/// Everything goes through the same `TripPackage.decode` an imported file uses,
/// so verification is not a path that only gets exercised later.
@Observable
final class TripLibrary {
    enum LoadState {
        case loading
        case loaded([TripPackage])
        case failed(String)
    }

    private(set) var state: LoadState = .loading

    init() {
        load()
    }

    func load() {
        state = .loading
        do {
            let packages = try Self.bundledPackages()
            state = packages.isEmpty
                ? .failed("No trips yet. Export one from the planner and open it on this phone.")
                : .loaded(packages)
        } catch {
            // Surfaced rather than swallowed: a package that fails verification
            // is the one thing that must never quietly become a route someone
            // then follows up a mountain.
            state = .failed(String(describing: error))
        }
    }

    /// Where imported trips live. Anything dropped in here through Files,
    /// AirDrop or iTunes file sharing is picked up on next launch.
    static var tripsDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("trips", isDirectory: true)
    }

    private static func bundledPackages() throws -> [TripPackage] {
        let bundled = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let imported = (try? FileManager.default.contentsOfDirectory(
            at: tripsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []

        return try (bundled + imported)
            .filter { $0.lastPathComponent.hasSuffix(".trippackage.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            // Verification is not skipped for imported files — a package that
            // arrived over AirDrop is exactly the one worth checking, and a
            // failure here surfaces rather than becoming a route someone
            // follows up a mountain.
            .map { try TripPackage.decode(from: Data(contentsOf: $0)) }
    }
}

extension TripPackage {
    var distanceKM: Double { Double(plannedRoute.stats.distanceM) / 1000 }

    /// Checkpoints that mark an overnight stop — the ones that structure a
    /// multi-day walk, as opposed to every water source and viewpoint.
    var overnightCheckpoints: [Checkpoint] {
        checkpoints.filter { $0.kind == "overnight" }
    }
}
