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
    /// The outcome of the last import, for the screen to report.
    var lastImport: ImportResult?

    enum ImportResult: Identifiable {
        case added(String)
        case failed(String)

        var id: String {
            switch self {
            case .added(let name): "added-\(name)"
            case .failed(let message): "failed-\(message)"
            }
        }
    }

    /// Import and remember what happened, for callers that have nowhere to
    /// throw to — a file arriving from AirDrop has no call site to catch it.
    func receive(_ url: URL) {
        do {
            let package = try importTrip(from: url)
            lastImport = .added(package.trip.name)
        } catch {
            lastImport = .failed(Self.explain(error))
        }
    }

    /// A message a walker can act on, rather than a decoding error dump.
    private static func explain(_ error: Error) -> String {
        if let error = error as? TripPackageError { return error.description }
        if error is DecodingError {
            return "That file is not a trip package the app understands."
        }
        return error.localizedDescription
    }

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

    /// Take a trip package from somewhere else on the phone and keep it.
    ///
    /// The one thing the app could not do. A trip reached this device by cable
    /// and a `devicectl` command, which is fine for the person with the cable
    /// and leaves everybody else holding an app with nothing in it.
    ///
    /// Verified before it is kept, not after. A file that fails is reported and
    /// discarded — half-importing a route someone then follows up a mountain is
    /// the one outcome worth being strict about.
    @discardableResult
    func importTrip(from url: URL) throws -> TripPackage {
        // Files handed over by another app arrive security-scoped, and reading
        // without asking fails with a permission error that looks like a
        // missing file.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let package = try TripPackage.decode(from: data)

        try FileManager.default.createDirectory(
            at: Self.tripsDirectory, withIntermediateDirectories: true
        )
        // Named by trip id, so importing a corrected export replaces the trip
        // it corrects instead of sitting beside it under whatever the file was
        // called this time.
        let destination = Self.tripsDirectory
            .appendingPathComponent("\(package.tripId).trippackage.json")
        try data.write(to: destination, options: .atomic)

        load()
        return package
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
