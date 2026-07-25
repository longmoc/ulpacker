// swift-tools-version: 6.0
import PackageDescription

// TripCore holds everything the companion can verify without a device: the
// TripPackage decoder, the canonical hash, and (later) the route maths. Keeping
// it a plain SwiftPM package means `swift test` runs it from the command line in
// seconds — the app target and Core Location stay out of this loop deliberately,
// because those are the parts that need an iPhone and a two-hour walk.
let package = Package(
    name: "TripCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TripCore", targets: ["TripCore"])
    ],
    targets: [
        .target(name: "TripCore"),
        // The golden fixtures are NOT declared as bundle resources. The tests
        // read them from the repo root via #filePath, so both suites open the
        // exact same bytes on disk — a copied bundle resource would be free to
        // drift, which is the one failure mode these fixtures exist to prevent.
        .testTarget(name: "TripCoreTests", dependencies: ["TripCore"])
    ]
)
