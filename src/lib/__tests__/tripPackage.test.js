import { describe, it, expect } from "vitest";
import {
  buildTripPackage,
  validateTripPackage,
  canonicalJson,
  fnv1a64,
  computeContentHash,
  TRIP_PACKAGE_FORMAT,
  TRIP_PACKAGE_VERSION,
  HASH_ALGORITHM,
  DEFAULT_OFF_ROUTE_ENTER_M,
  DEFAULT_OFF_ROUTE_EXIT_M
} from "../tripPackage.js";

// A short synthetic route: two segments, climbing then descending, with an
// overnight checkpoint in the middle so buildDays() produces two days.
function makeTrack() {
  return {
    segments: [
      {
        points: [
          [45.9, 6.8, 1000],
          [45.91, 6.81, 1200],
          [45.92, 6.82, 1400]
        ]
      },
      {
        points: [
          [45.93, 6.83, 1300],
          [45.94, 6.84, 1100]
        ]
      }
    ]
  };
}

function makeTrip(overrides = {}) {
  return {
    id: "trip-1",
    name: "Test Trail",
    description: "A short test route",
    startName: "Trailhead",
    finishName: "End",
    loop: false,
    startDayNumber: 1,
    image: "data:image/png;base64,AAAA",
    packId: "pack-1",
    createdAt: "2026-01-01T00:00:00.000Z",
    dayNotes: {},
    extraDays: [],
    checkpoints: [
      {
        id: "cp-1",
        name: "Refuge",
        note: "Book ahead",
        kind: "overnight",
        source: "manual",
        anchor: {
          segmentIndex: 0,
          alongSegmentM: 1200,
          routeDistanceM: 1200,
          lat: 45.915,
          lng: 6.815,
          ele: 1300,
          offsetM: 5,
          sourceLat: 45.915,
          sourceLng: 6.815
        }
      }
    ],
    ...overrides
  };
}

const build = (tripOverrides, options) =>
  buildTripPackage(makeTrip(tripOverrides), makeTrack(), {
    publishedAt: "2026-07-25T10:00:00.000Z",
    ...options
  });

describe("canonicalJson", () => {
  it("sorts object keys so member order cannot change the hash", () => {
    expect(canonicalJson({ b: 1, a: 2 })).toBe(canonicalJson({ a: 2, b: 1 }));
    expect(canonicalJson({ b: 1, a: 2 })).toBe('{"a":2,"b":1}');
  });

  it("drops null and undefined members so absent and null hash alike", () => {
    expect(canonicalJson({ a: 1, b: null, c: undefined })).toBe('{"a":1}');
  });

  it("formats non-integers at fixed decimals, integers as digits", () => {
    // JS and Swift disagree on shortest-round-trip float printing, so the rule
    // has to be explicit or the two implementations would hash differently.
    expect(canonicalJson(1)).toBe("1");
    expect(canonicalJson(-3)).toBe("-3");
    expect(canonicalJson(0.1)).toBe("0.100000");
    expect(canonicalJson(45.915)).toBe("45.915000");
  });

  it("preserves array order", () => {
    expect(canonicalJson([3, 1, 2])).toBe("[3,1,2]");
    expect(canonicalJson([1, 2, 3])).not.toBe(canonicalJson([3, 2, 1]));
  });

  it("escapes strings via JSON rules", () => {
    expect(canonicalJson('a"b')).toBe('"a\\"b"');
    expect(canonicalJson({ "ké": "ü" })).toBe('{"ké":"ü"}');
  });

  it("refuses non-finite numbers rather than emitting null silently", () => {
    expect(() => canonicalJson(NaN)).toThrow(TypeError);
    expect(() => canonicalJson(Infinity)).toThrow(TypeError);
  });
});

describe("fnv1a64", () => {
  it("matches the published FNV-1a 64 test vectors", () => {
    // Reference values for the 64-bit variant — these pin the algorithm so a
    // Swift port can be checked against the same numbers.
    expect(fnv1a64("")).toBe("cbf29ce484222325");
    expect(fnv1a64("a")).toBe("af63dc4c8601ec8c");
    expect(fnv1a64("foobar")).toBe("85944171f73967e8");
  });

  it("hashes UTF-8 bytes, not code units", () => {
    expect(fnv1a64("é")).toBe(fnv1a64("é"));
    expect(fnv1a64("é")).not.toBe(fnv1a64("e"));
  });

  it("always returns 16 hex digits", () => {
    for (const s of ["", "a", "the quick brown fox", "🥾"]) {
      expect(fnv1a64(s)).toMatch(/^[0-9a-f]{16}$/);
    }
  });
});

describe("buildTripPackage", () => {
  it("produces a v1 package with the declared format and hash algorithm", () => {
    const pkg = build();
    expect(pkg.format).toBe(TRIP_PACKAGE_FORMAT);
    expect(pkg.schemaVersion).toBe(TRIP_PACKAGE_VERSION);
    expect(pkg.hashAlgorithm).toBe(HASH_ALGORITHM);
    expect(pkg.tripId).toBe("trip-1");
    expect(pkg.revision).toBe(1);
  });

  it("carries route geometry and derived stats", () => {
    const pkg = build();
    expect(pkg.plannedRoute.segments).toHaveLength(2);
    expect(pkg.plannedRoute.stats.pointCount).toBe(5);
    expect(pkg.plannedRoute.stats.segmentCount).toBe(2);
    expect(pkg.plannedRoute.stats.distanceM).toBeGreaterThan(0);
    expect(pkg.plannedRoute.stats.maxEle).toBe(1400);
    expect(pkg.plannedRoute.stats.minEle).toBe(1000);
  });

  it("omits planner-only fields the companion has no use for", () => {
    const pkg = build();
    // Cover images are data URIs and gear/pack state is out of scope; shipping
    // them would bloat every package for no navigational gain.
    expect(pkg.trip.image).toBeUndefined();
    expect(pkg.trip.packId).toBeUndefined();
    expect(pkg.trip.createdAt).toBeUndefined();
    expect(JSON.stringify(pkg)).not.toContain("data:image");
  });

  it("flattens checkpoints to the navigation subset", () => {
    const [cp] = build().checkpoints;
    expect(cp).toEqual({
      id: "cp-1",
      name: "Refuge",
      note: "Book ahead",
      kind: "overnight",
      routeDistanceM: 1200,
      lat: 45.915,
      lng: 6.815,
      ele: 1300
    });
    // Internal anchoring detail stays behind.
    expect(cp.segmentIndex).toBeUndefined();
    expect(cp.offsetM).toBeUndefined();
  });

  it("sorts checkpoints along the route regardless of input order", () => {
    // The companion walks these as a sequence, so ordering has to be guaranteed
    // by the contract rather than inherited from however the caller built them.
    const at = (routeDistanceM, id) => ({
      id,
      name: id,
      kind: "poi",
      anchor: { lat: 45.91, lng: 6.81, ele: 1200, routeDistanceM }
    });
    const pkg = build({ checkpoints: [at(2000, "c"), at(100, "a"), at(900, "b")] });
    expect(pkg.checkpoints.map((c) => c.id)).toEqual(["a", "b", "c"]);
  });

  it("drops checkpoints without usable coordinates", () => {
    const pkg = build({
      checkpoints: [
        { id: "bad", name: "No anchor", kind: "poi" },
        { id: "worse", name: "NaN", kind: "poi", anchor: { lat: NaN, lng: 6.8, routeDistanceM: 0 } }
      ]
    });
    expect(pkg.checkpoints).toEqual([]);
  });

  it("builds an itinerary split at the overnight checkpoint", () => {
    const pkg = build();
    expect(pkg.itinerary).toHaveLength(2);
    expect(pkg.itinerary[0].startBoundary).toBe("start");
    expect(pkg.itinerary[0].endBoundary).toBe("cp-1");
    expect(pkg.itinerary[1].endBoundary).toBe("finish");
    expect(pkg.itinerary[1].startRouteM).toBe(pkg.itinerary[0].endRouteM);
  });

  it("attaches each day's note by its starting boundary", () => {
    const pkg = build({ dayNotes: { start: "Early start", "cp-1": "Long climb" } });
    expect(pkg.itinerary[0].note).toBe("Early start");
    expect(pkg.itinerary[1].note).toBe("Long climb");
  });

  it("carries off-track extra days without geometry", () => {
    const pkg = build({
      extraDays: [{ id: "x1", before: "start", title: "Travel to Chamonix", note: "Train" }]
    });
    expect(pkg.extraDays).toEqual([
      { id: "x1", before: "start", title: "Travel to Chamonix", note: "Train" }
    ]);
  });

  it("defaults the off-route thresholds and allows a per-trip override", () => {
    expect(build().navigationDefaults).toEqual({
      offRouteEnterM: DEFAULT_OFF_ROUTE_ENTER_M,
      offRouteExitM: DEFAULT_OFF_ROUTE_EXIT_M
    });
    const relaxed = build(undefined, { offRouteEnterM: 150, offRouteExitM: 80 });
    expect(relaxed.navigationDefaults).toEqual({ offRouteEnterM: 150, offRouteExitM: 80 });
  });

  it("returns null when there is no usable route", () => {
    expect(buildTripPackage(makeTrip(), null)).toBeNull();
    expect(buildTripPackage(makeTrip(), { segments: [] })).toBeNull();
    // A single point cannot form a route to follow.
    expect(buildTripPackage(makeTrip(), { segments: [{ points: [[45.9, 6.8, 1000]] }] })).toBeNull();
    expect(buildTripPackage(null, makeTrack())).toBeNull();
  });

  it("clamps revision to a positive integer", () => {
    expect(build(undefined, { revision: 7 }).revision).toBe(7);
    expect(build(undefined, { revision: 0 }).revision).toBe(1);
    expect(build(undefined, { revision: -3 }).revision).toBe(1);
    expect(build(undefined, { revision: "nope" }).revision).toBe(1);
  });
});

describe("contentHash", () => {
  it("is stable across exports of unchanged content", () => {
    // The whole point: re-exporting the same trip must not look like a change.
    const a = build(undefined, { publishedAt: "2026-07-25T10:00:00.000Z" });
    const b = build(undefined, { publishedAt: "2026-08-01T23:59:00.000Z" });
    expect(a.contentHash).toBe(b.contentHash);
  });

  it("changes when navigational content changes", () => {
    const base = build().contentHash;
    expect(build({ name: "Renamed" }).contentHash).not.toBe(base);
    expect(build({ dayNotes: { start: "note" } }).contentHash).not.toBe(base);
    expect(build(undefined, { offRouteEnterM: 150 }).contentHash).not.toBe(base);
    expect(build(undefined, { revision: 2 }).contentHash).not.toBe(base);
  });

  it("recomputes to the value stored in the package", () => {
    const pkg = build();
    expect(computeContentHash(pkg)).toBe(pkg.contentHash);
  });

  it("survives a JSON round trip", () => {
    const pkg = build();
    const reparsed = JSON.parse(JSON.stringify(pkg));
    expect(computeContentHash(reparsed)).toBe(pkg.contentHash);
  });
});

describe("validateTripPackage", () => {
  it("accepts a freshly built package", () => {
    expect(validateTripPackage(build())).toEqual({ ok: true, errors: [] });
  });

  it("accepts a package that has been through JSON", () => {
    const result = validateTripPackage(JSON.parse(JSON.stringify(build())));
    expect(result.ok).toBe(true);
  });

  it("rejects non-objects and foreign formats", () => {
    expect(validateTripPackage(null).ok).toBe(false);
    expect(validateTripPackage([]).ok).toBe(false);
    expect(validateTripPackage({ format: "something-else" }).ok).toBe(false);
  });

  it("rejects a schemaVersion this build does not know", () => {
    const pkg = { ...build(), schemaVersion: 2 };
    const result = validateTripPackage(pkg);
    expect(result.ok).toBe(false);
    expect(result.errors[0]).toMatch(/schemaVersion/);
  });

  it("detects tampering through the content hash", () => {
    const pkg = build();
    pkg.trip.name = "Tampered";
    const result = validateTripPackage(pkg);
    expect(result.ok).toBe(false);
    expect(result.errors.some((e) => e.includes("contentHash mismatch"))).toBe(true);
  });

  it("rejects out-of-range coordinates", () => {
    const pkg = build();
    pkg.plannedRoute.segments[0].points[0] = [91, 6.8, 1000];
    pkg.contentHash = computeContentHash(pkg);
    const result = validateTripPackage(pkg);
    expect(result.ok).toBe(false);
    expect(result.errors.some((e) => e.includes("out-of-range"))).toBe(true);
  });

  it("rejects an empty route", () => {
    const pkg = build();
    pkg.plannedRoute.segments = [];
    pkg.contentHash = computeContentHash(pkg);
    expect(validateTripPackage(pkg).ok).toBe(false);
  });

  it("reports a missing hash rather than throwing", () => {
    const pkg = build();
    delete pkg.contentHash;
    const result = validateTripPackage(pkg);
    expect(result.ok).toBe(false);
    expect(result.errors).toContain("Missing contentHash.");
  });
});
