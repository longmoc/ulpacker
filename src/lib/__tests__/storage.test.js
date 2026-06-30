import { describe, it, expect, beforeEach } from "vitest";
import { STORAGE_KEY, readStorage, normalizeData, defaultData } from "../storage.js";

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
});
