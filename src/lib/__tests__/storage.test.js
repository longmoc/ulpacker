import { describe, it, expect, beforeEach } from "vitest";
import {
  STORAGE_KEY,
  LEGACY_STORAGE_KEY_V3,
  TRACKS_KEY,
  SCHEMA_VERSION,
  readStorage,
  readLocalBundle,
  normalizeData,
  normalizeTrips,
  sanitizeTracks,
  buildPortableBundle,
  applyPortableBundle,
  gcTracks,
  defaultData
} from "../storage.js";

beforeEach(() => {
  const store = new Map();
  globalThis.localStorage = {
    getItem: (k) => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
    clear: () => store.clear()
  };
});

describe("readStorage", () => {
  it("returns default data (seeded with Egg) when storage is empty", () => {
    const data = readStorage();
    expect(data.gears.some((g) => g.name === "Egg")).toBe(true);
    expect(data.packs).toHaveLength(1);
  });

  it("falls back to defaults on malformed JSON", () => {
    localStorage.setItem(STORAGE_KEY, "{not json");
    expect(readStorage().gears.length).toBeGreaterThan(0);
  });

  it("migrates a legacy single `category` into `categories`", () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        gears: [{ id: "g1", name: "Stove", category: "Cooking", variants: [{ weight: 90 }] }],
        packs: [{ id: "p1", name: "Trip" }],
        packItems: []
      })
    );
    const stove = readStorage().gears.find((g) => g.name === "Stove");
    expect(stove.categories).toEqual(["Cooking"]);
  });

  it("drops pack items whose gear no longer exists", () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        gears: [{ id: "g1", name: "Stove", categories: ["Cooking"], variants: [{ weight: 90 }] }],
        packs: [{ id: "p1", name: "Trip" }],
        packItems: [
          { id: "i1", packId: "p1", gearId: "g1", quantity: 1, weight: 90 },
          { id: "i2", packId: "p1", gearId: "ghost", quantity: 1, weight: 10 }
        ]
      })
    );
    const items = readStorage().packItems;
    expect(items).toHaveLength(1);
    expect(items[0].id).toBe("i1");
  });

  it("does NOT re-seed Egg into existing data that omits it (deletion sticks)", () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        gears: [{ id: "g1", name: "Stove", categories: ["Cooking"], variants: [{ weight: 90 }] }],
        packs: [{ id: "p1", name: "Trip" }],
        packItems: []
      })
    );
    expect(readStorage().gears.some((g) => g.name === "Egg")).toBe(false);
  });

  it("preserves variant names and ids across a save -> read round trip", () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        gears: [
          {
            id: "g1",
            name: "Backpack",
            categories: ["Pack"],
            variants: [
              { id: "v40", name: "40L", weight: 920 },
              { id: "v55", name: "55L", weight: 1100 }
            ]
          }
        ],
        packs: [{ id: "p1", name: "Trip" }],
        packItems: []
      })
    );
    const pack = readStorage().gears.find((g) => g.name === "Backpack");
    expect(pack.variants).toEqual([
      { id: "v40", name: "40L", weight: 920, price: 0 },
      { id: "v55", name: "55L", weight: 1100, price: 0 }
    ]);
  });
});

describe("normalizeData", () => {
  it("returns null for unrecognizable input (so import can reject it)", () => {
    expect(normalizeData(null)).toBeNull();
    expect(normalizeData({})).toBeNull();
    expect(normalizeData({ gears: "nope" })).toBeNull();
  });

  it("carries favorite + purchase markers through normalization", () => {
    const data = normalizeData({
      gears: [
        { id: "g1", name: "Tent", categories: ["Shelter"], favorite: true, purchase: "need", variants: [{ weight: 1200 }] },
        { id: "g2", name: "Stove", categories: ["Cooking"], purchase: "bogus", variants: [{ weight: 90 }] }
      ],
      packs: [{ id: "p1", name: "Trip" }],
      packItems: []
    });
    expect(data.gears.find((g) => g.name === "Tent")).toMatchObject({ favorite: true, purchase: "need" });
    expect(data.gears.find((g) => g.name === "Stove")).toMatchObject({ favorite: false, purchase: "" });
  });

  it("preserves a pack cover image and defaults a missing one to empty", () => {
    const data = normalizeData({
      gears: [{ id: "g1", name: "Quilt", categories: ["Sleep"], variants: [{ weight: 600 }] }],
      packs: [
        { id: "p1", name: "With cover", image: "data:image/jpeg;base64,AAA" },
        { id: "p2", name: "No cover" }
      ],
      packItems: []
    });
    expect(data.packs.find((p) => p.id === "p1").image).toBe("data:image/jpeg;base64,AAA");
    expect(data.packs.find((p) => p.id === "p2").image).toBe("");
  });

  it("strips non-data-URL cover images (remote URLs from a hostile backup)", () => {
    const data = normalizeData({
      gears: [{ id: "g1", name: "Quilt", categories: ["Sleep"], variants: [{ weight: 600 }] }],
      packs: [
        { id: "p1", name: "Tracker", image: "https://evil.example/pixel.png" },
        { id: "p2", name: "Script", image: "javascript:alert(1)" },
        { id: "p3", name: "NotImage", image: "data:text/html,<script>1</script>" }
      ],
      packItems: []
    });
    expect(data.packs.map((p) => p.image)).toEqual(["", "", ""]);
  });

  it("normalizes a valid backup object without touching localStorage", () => {
    const data = normalizeData({
      gears: [{ id: "g1", name: "Quilt", categories: ["Sleep"], variants: [{ weight: 600 }] }],
      packs: [{ id: "p1", name: "Trip" }],
      packItems: [{ id: "i1", packId: "p1", gearId: "g1", quantity: 1, weight: 600 }]
    });
    expect(data.gears.map((g) => g.name)).toEqual(["Quilt"]);
    expect(data.packItems).toHaveLength(1);
  });
});

describe("defaultData", () => {
  it("returns fresh objects on each call (no shared references)", () => {
    expect(defaultData()).not.toBe(defaultData());
  });

  it("includes schemaVersion 4 and an empty trips array", () => {
    const d = defaultData();
    expect(d.schemaVersion).toBe(SCHEMA_VERSION);
    expect(d.trips).toEqual([]);
  });
});

const track = () => ({ segments: [{ points: [[45, 6, 100], [45, 6.01, 110], [45, 6.02, 120]] }] });

const tripWith = (trackId, extra = {}) => ({
  id: "trip1",
  name: "TMB",
  packId: "",
  trackRef: { id: trackId, revision: 1 },
  stats: { distanceM: 0 },
  checkpoints: [],
  ...extra
});

describe("normalizeTrips", () => {
  it("recomputes canonical stats from geometry, ignoring cached values", () => {
    const tracks = { trk_a: track() };
    const forged = tripWith("trk_a", { stats: { distanceM: 999999, ascentM: 999999 } });
    const [trip] = normalizeTrips([forged], new Set(), tracks);
    expect(trip.stats.distanceM).toBeLessThan(5000);
    expect(trip.stats.metricsVersion).toBe(1);
    expect(trip.trackRef.pointCount).toBe(3);
    expect(trip.trackRef.segmentCount).toBe(1);
  });

  it("keeps a trip whose track asset is missing (not dropped)", () => {
    const [trip] = normalizeTrips([tripWith("gone")], new Set(), {});
    expect(trip).toBeTruthy();
    expect(trip.trackRef.id).toBe("gone");
  });

  it("resets packId to '' when the linked pack does not exist", () => {
    const [trip] = normalizeTrips([tripWith("trk_a", { packId: "nope" })], new Set(), { trk_a: track() });
    expect(trip.packId).toBe("");
  });

  it("clamps a checkpoint anchor to the real track length and recomputes routeDistanceM", () => {
    const tracks = { trk_a: track() };
    const cp = {
      id: "c1", name: "Camp", kind: "overnight",
      anchor: { segmentIndex: 5, alongSegmentM: 99999, routeDistanceM: 99999, lat: 45, lng: 6.01 }
    };
    const [trip] = normalizeTrips([tripWith("trk_a", { checkpoints: [cp] })], new Set(), tracks);
    expect(trip.checkpoints[0].anchor.segmentIndex).toBe(0);
    expect(trip.checkpoints[0].anchor.routeDistanceM).toBeLessThan(5000);
  });

  it("sanitizes boundaries and clamps them to the track length", () => {
    const tracks = { trk_a: track() }; // ~2.36 km straight track
    const raw = tripWith("trk_a", { boundaries: [1000, -50, 99999, "x", 1500] });
    const [trip] = normalizeTrips([raw], new Set(), tracks);
    expect(trip.boundaries.every((n) => Number.isFinite(n) && n > 1)).toBe(true);
    expect(trip.boundaries.every((n) => n < trip.stats.distanceM)).toBe(true);
    // sorted ascending
    expect(trip.boundaries).toEqual([...trip.boundaries].sort((a, b) => a - b));
  });

  it("enforces the MAX_TRIPS cap", () => {
    const many = Array.from({ length: 30 }, (_, i) => tripWith("trk_a", { id: `t${i}` }));
    expect(normalizeTrips(many, new Set(), { trk_a: track() }).length).toBeLessThanOrEqual(20);
  });
});

describe("sanitizeTracks", () => {
  it("drops segments with fewer than two valid points", () => {
    const out = sanitizeTracks({ a: { segments: [{ points: [[45, 6, 1]] }, { points: [[45, 6, 1], [45.001, 6, 2]] }] } });
    expect(out.a.segments).toHaveLength(1);
  });

  it("drops out-of-range coordinates", () => {
    const out = sanitizeTracks({ a: { segments: [{ points: [[999, 6, 1], [45, 6, 1], [45.001, 6, 2]] }] } });
    expect(out.a.segments[0].points).toHaveLength(2);
  });
});

describe("bundle codec", () => {
  it("round-trips a doc + tracks through build/apply and GCs orphans", () => {
    const doc = { ...defaultData(), trips: [tripWith("trk_a")], updatedAt: "2026-01-01T00:00:00Z" };
    const tracks = { trk_a: track(), trk_orphan: track() };
    const bundle = buildPortableBundle(doc, tracks);
    const applied = applyPortableBundle(bundle);
    expect(applied.doc.trips).toHaveLength(1);
    expect(applied.tracks.trk_a).toBeTruthy();
    expect(applied.tracks.trk_orphan).toBeUndefined(); // orphan GC'd
  });

  it("gcTracks keeps only referenced assets", () => {
    const kept = gcTracks([{ trackRef: { id: "keep" } }], { keep: track(), drop: track() });
    expect(kept.keep).toBeTruthy();
    expect(kept.drop).toBeUndefined();
  });
});

describe("readLocalBundle migration", () => {
  it("migrates v3 → v4 without bumping updatedAt and leaves v3 in place", () => {
    const v3 = { gears: defaultData().gears, packs: defaultData().packs, packItems: [], updatedAt: "2026-05-01T00:00:00Z" };
    localStorage.setItem(LEGACY_STORAGE_KEY_V3, JSON.stringify(v3));
    const { doc, migrated } = readLocalBundle();
    expect(migrated).toBe(true);
    expect(doc.schemaVersion).toBe(SCHEMA_VERSION);
    expect(doc.trips).toEqual([]);
    expect(doc.updatedAt).toBe("2026-05-01T00:00:00Z"); // NOT bumped
    expect(localStorage.getItem(LEGACY_STORAGE_KEY_V3)).toBeTruthy(); // kept for rollback
  });

  it("preserves an empty updatedAt through migration (never overwrites cloud on first sign-in)", () => {
    const v3 = { gears: defaultData().gears, packs: defaultData().packs, packItems: [] };
    localStorage.setItem(LEGACY_STORAGE_KEY_V3, JSON.stringify(v3));
    expect(readLocalBundle().doc.updatedAt).toBe("");
  });

  it("prefers v4 when present", () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ ...defaultData(), updatedAt: "2026-06-01T00:00:00Z" }));
    localStorage.setItem(LEGACY_STORAGE_KEY_V3, JSON.stringify({ gears: defaultData().gears, packs: [], packItems: [], updatedAt: "2020-01-01T00:00:00Z" }));
    expect(readLocalBundle().doc.updatedAt).toBe("2026-06-01T00:00:00Z");
  });
});
