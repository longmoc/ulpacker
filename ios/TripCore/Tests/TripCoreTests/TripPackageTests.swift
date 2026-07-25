import Foundation
import Testing
@testable import TripCore

/// The cross-language contract tests.
///
/// These assert against the *same files* the JS suite asserts against
/// (`fixtures/trips/`, symlinked into this target's resources). The pinned
/// hashes and numbers below are duplicated from
/// `src/lib/__tests__/fixtures.test.js` on purpose: that duplication is the
/// mechanism. If the two route implementations drift, one suite goes red while
/// the other stays green, and the disagreement is visible instead of silent.
struct TripPackageTests {
    /// Reads straight from `fixtures/trips/` at the repo root — the same file
    /// the JS suite reads. Resolved from `#filePath` rather than copied into a
    /// bundle so there is exactly one copy of each fixture in existence.
    static func fixtureData(_ name: String) throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // TripCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // TripCore
            .deletingLastPathComponent()  // ios
            .deletingLastPathComponent()  // <repo root>
        let url = repoRoot
            .appendingPathComponent("fixtures/trips")
            .appendingPathComponent("\(name).trippackage.json")
        return try Data(contentsOf: url)
    }

    // MARK: - Canonical form

    @Test func canonicalJSONSortsKeysAndDropsNulls() throws {
        let data = Data(#"{"b":1,"a":2,"c":null}"#.utf8)
        #expect(try CanonicalJSON.canonicalize(data: data) == #"{"a":2,"b":1}"#)
    }

    @Test func canonicalJSONDistinguishesBooleansFromNumbers() throws {
        // JSONSerialization funnels both through NSNumber; `true` must not
        // become `1`, or Swift and JS would hash the same package differently.
        let data = Data(#"{"flag":true,"off":false,"one":1}"#.utf8)
        #expect(try CanonicalJSON.canonicalize(data: data) == #"{"flag":true,"off":false,"one":1}"#)
    }

    @Test func canonicalJSONFormatsNumbersLikeJavaScript() {
        #expect(CanonicalJSON.canonicalNumber(1) == "1")
        #expect(CanonicalJSON.canonicalNumber(-3) == "-3")
        #expect(CanonicalJSON.canonicalNumber(0.1) == "0.100000")
        #expect(CanonicalJSON.canonicalNumber(45.915) == "45.915000")
    }

    @Test func canonicalJSONPreservesArrayOrder() throws {
        let data = Data("[3,1,2]".utf8)
        #expect(try CanonicalJSON.canonicalize(data: data) == "[3,1,2]")
    }

    @Test func canonicalJSONEscapesLikeJSONStringify() {
        #expect(CanonicalJSON.escape("a\"b") == "\"a\\\"b\"")
        #expect(CanonicalJSON.escape("line\nbreak") == "\"line\\nbreak\"")
        // Non-ASCII stays raw, exactly as JSON.stringify leaves it.
        #expect(CanonicalJSON.escape("ké") == "\"ké\"")
    }

    @Test func sortsKeysByUTF16CodeUnit() {
        #expect(CanonicalJSON.lessThanByUTF16("a", "b"))
        #expect(CanonicalJSON.lessThanByUTF16("Z", "a")) // uppercase sorts first
        #expect(!CanonicalJSON.lessThanByUTF16("b", "a"))
        #expect(CanonicalJSON.lessThanByUTF16("ab", "abc"))
    }

    // MARK: - Hash

    @Test func matchesPublishedFNV1aVectors() {
        // The same vectors are pinned in the JS suite; they are the shared
        // reference point for both implementations.
        #expect(FNV1a.hash64("") == "cbf29ce484222325")
        #expect(FNV1a.hash64("a") == "af63dc4c8601ec8c")
        #expect(FNV1a.hash64("foobar") == "85944171f73967e8")
    }

    @Test func hashesUTF8BytesNotCodeUnits() {
        #expect(FNV1a.hash64("é") != FNV1a.hash64("e"))
    }

    @Test func contentHashIgnoresPublishedAt() throws {
        // Re-exporting an unchanged trip must not look like a change.
        let a = Data(#"{"format":"x","publishedAt":"2026-01-01","contentHash":"zz","v":1}"#.utf8)
        let b = Data(#"{"format":"x","publishedAt":"2030-12-31","contentHash":"yy","v":1}"#.utf8)
        let hashA = try CanonicalJSON.canonicalize(data: a, omittingTopLevelKeys: ["contentHash", "publishedAt"])
        let hashB = try CanonicalJSON.canonicalize(data: b, omittingTopLevelKeys: ["contentHash", "publishedAt"])
        #expect(hashA == hashB)
    }

    // MARK: - Fixtures

    @Test(arguments: ["synthetic-ridge", "tmb-ccw"])
    func decodesAndVerifiesFixture(name: String) throws {
        let data = try Self.fixtureData(name)
        let package = try TripPackage.decode(from: data)
        #expect(package.format == TripPackage.expectedFormat)
        #expect(package.schemaVersion == 1)
    }

    @Test(arguments: ["synthetic-ridge", "tmb-ccw"])
    func checkpointsAreOrderedAlongTheRoute(name: String) throws {
        let package = try TripPackage.decode(from: Self.fixtureData(name))
        let distances = package.checkpoints.map(\.routeDistanceM)
        #expect(distances == distances.sorted())
    }

    @Test(arguments: ["synthetic-ridge", "tmb-ccw"])
    func itineraryIsContiguousAndCoversTheRoute(name: String) throws {
        let package = try TripPackage.decode(from: Self.fixtureData(name))
        let days = package.itinerary
        #expect(days.first?.startRouteM == 0)
        #expect(days.last?.endRouteM == package.plannedRoute.stats.distanceM)
        for (previous, next) in zip(days, days.dropFirst()) {
            #expect(next.startRouteM == previous.endRouteM)
        }
    }

    @Test func syntheticFixtureMatchesTheJavaScriptSuite() throws {
        let data = try Self.fixtureData("synthetic-ridge")
        #expect(try TripPackage.contentHash(of: data) == "032bf5c9be3fc1b2")

        let package = try TripPackage.decode(from: data)
        #expect(package.plannedRoute.stats.pointCount == 21)
        #expect(package.checkpoints.count == 1)
        #expect(package.checkpoints.first?.kind == "pass")
    }

    @Test func tmbFixtureMatchesTheJavaScriptSuite() throws {
        let data = try Self.fixtureData("tmb-ccw")
        // The moment of truth for the whole port: two independent
        // implementations of canonical JSON + FNV-1a over a real 164 km route
        // with 8561 points have to agree on one 16-digit number.
        #expect(try TripPackage.contentHash(of: data) == "5c0f23f2c177c903")

        let package = try TripPackage.decode(from: data)
        #expect(package.plannedRoute.stats.distanceM == 164_231)
        #expect(package.plannedRoute.stats.ascentM == 11_334)
        #expect(package.plannedRoute.stats.pointCount == 8561)
        #expect(package.plannedRoute.stats.segmentCount == 1)
        #expect(package.itinerary.count == 9)
        #expect(package.checkpoints.count == 54)
        #expect(package.trip.name == "Tour du Mont Blanc (CCW)")
    }

    @Test func decodesEveryPointOfTheRealRoute() throws {
        // Guards the compact `[lat, lng, ele]` wire form against a decoder that
        // quietly drops or mangles the optional third element.
        let package = try TripPackage.decode(from: Self.fixtureData("tmb-ccw"))
        let points = package.plannedRoute.segments.flatMap(\.points)
        #expect(points.count == package.plannedRoute.stats.pointCount)
        #expect(points.allSatisfy { (-90...90).contains($0.lat) && (-180...180).contains($0.lng) })
        #expect(points.contains { $0.ele != nil })
    }

    // MARK: - Rejection

    @Test func rejectsATamperedPackage() throws {
        var object = try JSONSerialization.jsonObject(
            with: Self.fixtureData("synthetic-ridge")
        ) as! [String: Any]
        var trip = object["trip"] as! [String: Any]
        trip["name"] = "Tampered"
        object["trip"] = trip
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: TripPackageError.self) {
            _ = try TripPackage.decode(from: data)
        }
    }

    @Test func rejectsAnUnknownSchemaVersion() throws {
        var object = try JSONSerialization.jsonObject(
            with: Self.fixtureData("synthetic-ridge")
        ) as! [String: Any]
        object["schemaVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: TripPackageError.unsupportedSchemaVersion(2)) {
            _ = try TripPackage.decode(from: data)
        }
    }

    @Test func rejectsAForeignFormat() throws {
        var object = try JSONSerialization.jsonObject(
            with: Self.fixtureData("synthetic-ridge")
        ) as! [String: Any]
        object["format"] = "something-else"
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: TripPackageError.wrongFormat("something-else")) {
            _ = try TripPackage.decode(from: data)
        }
    }

    @Test func toleratesUnknownFieldsFromANewerPlanner() throws {
        // Forward compatibility: an added field must not break decoding, and it
        // still contributes to the hash because hashing works on raw bytes.
        var object = try JSONSerialization.jsonObject(
            with: Self.fixtureData("synthetic-ridge")
        ) as! [String: Any]
        object["somethingNew"] = "from a future build"
        let dataWithExtra = try JSONSerialization.data(withJSONObject: object)

        let originalHash = try TripPackage.contentHash(of: Self.fixtureData("synthetic-ridge"))
        let newHash = try TripPackage.contentHash(of: dataWithExtra)
        #expect(newHash != originalHash)

        // Decoding still works; only the hash comparison would flag it.
        let decoded = try JSONDecoder().decode(TripPackage.self, from: dataWithExtra)
        #expect(decoded.trip.name == "Synthetic Ridge")
    }
}
