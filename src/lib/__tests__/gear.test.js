import { describe, it, expect } from "vitest";
import {
  normalizeCategories,
  primaryCategory,
  gearMergeKey,
  normalizeVariants,
  mergeGears,
  mergeOrCreateGear,
  nextPurchase
} from "../gear.js";

describe("normalizeCategories", () => {
  it("parses comma strings, trims, and dedupes", () => {
    expect(normalizeCategories("Food, Pack ,Food")).toEqual(["Food", "Pack"]);
  });

  it("falls back to Uncategorized when empty", () => {
    expect(normalizeCategories([])).toEqual(["Uncategorized"]);
    expect(normalizeCategories("")).toEqual(["Uncategorized"]);
  });
});

describe("primaryCategory", () => {
  it("returns the first category of an array", () => {
    expect(primaryCategory(["A", "B"])).toBe("A");
  });

  it("reads from a gear object, supporting legacy `category`", () => {
    expect(primaryCategory({ categories: ["X"] })).toBe("X");
    expect(primaryCategory({ category: "Legacy" })).toBe("Legacy");
  });
});

describe("gearMergeKey", () => {
  it("is case-insensitive and trimmed on name + itemType", () => {
    expect(gearMergeKey("  Egg ", "Fresh Food")).toBe(gearMergeKey("egg", "fresh food"));
  });
});

describe("normalizeVariants", () => {
  it("keeps only distinct non-zero weights", () => {
    const out = normalizeVariants([{ weight: 100 }, { weight: 100 }, { weight: 200 }]);
    expect(out.map((v) => v.weight)).toEqual([100, 200]);
  });

  it("drops zero-weight variants when any non-zero exists", () => {
    const out = normalizeVariants([{ weight: 0 }, { weight: 50 }]);
    expect(out.map((v) => v.weight)).toEqual([50]);
  });

  it("keeps a single zero variant when all are zero", () => {
    const out = normalizeVariants([{ weight: 0 }, { weight: 0 }]);
    expect(out).toHaveLength(1);
    expect(out[0].weight).toBe(0);
  });

  it("preserves custom variant names and ids", () => {
    const out = normalizeVariants([
      { id: "v40", name: "40L", weight: 920 },
      { id: "v55", name: "55L", weight: 1100 }
    ]);
    expect(out.map((v) => v.name)).toEqual(["40L", "55L"]);
    expect(out.map((v) => v.id)).toEqual(["v40", "v55"]);
  });

  it("generates default names only when none are provided", () => {
    const out = normalizeVariants([{ weight: 100 }, { weight: 200 }]);
    expect(out.map((v) => v.name)).toEqual(["Default", "Variant 2"]);
  });

  it("keeps a per-variant price and fills missing prices with 0", () => {
    const out = normalizeVariants([
      { name: "40L", weight: 920, price: 1200 },
      { name: "55L", weight: 1100 }
    ]);
    expect(out.map((v) => v.price)).toEqual([1200, 0]);
  });
});

describe("mergeGears", () => {
  it("merges duplicates by name+itemType and maps old ids to the survivor", () => {
    const { gears, idMap } = mergeGears([
      { id: "a", name: "Egg", itemType: "Fresh Food", categories: ["Food"], variants: [{ weight: 58 }] },
      { id: "b", name: "egg", itemType: "fresh food", categories: ["Protein"], variants: [{ weight: 60 }] }
    ]);
    expect(gears).toHaveLength(1);
    expect(gears[0].categories).toEqual(["Food", "Protein"]);
    expect(gears[0].variants.map((v) => v.weight)).toEqual([58, 60]);
    // both original ids resolve to the single survivor
    expect(idMap.get("a")).toBe(gears[0].id);
    expect(idMap.get("b")).toBe(gears[0].id);
  });
});

describe("mergeOrCreateGear", () => {
  it("creates a new gear when nothing matches", () => {
    const { gears, gear } = mergeOrCreateGear([], { name: "Tent", variants: [{ weight: 1200 }] });
    expect(gears).toHaveLength(1);
    expect(gear.name).toBe("Tent");
    expect(gear.categories).toEqual(["Uncategorized"]);
  });

  it("merges into an existing gear, appending categories and variants", () => {
    const prev = [
      { id: "x", name: "Tent", itemType: "", categories: ["Shelter"], description: "", notes: "", variants: [{ id: "v1", name: "Default", weight: 1200 }] }
    ];
    const { gears } = mergeOrCreateGear(prev, {
      name: "Tent",
      categories: ["Sleep"],
      variants: [{ weight: 1300 }]
    });
    expect(gears).toHaveLength(1);
    expect(gears[0].categories).toEqual(["Shelter", "Sleep"]);
    expect(gears[0].variants.map((v) => v.weight)).toEqual([1200, 1300]);
  });

  it("names an unnamed incoming gear", () => {
    const { gear } = mergeOrCreateGear([], { name: "   ", variants: [{ weight: 1 }] });
    expect(gear.name).toBe("Unnamed gear");
  });

  it("defaults favorite/purchase on create and validates them", () => {
    const a = mergeOrCreateGear([], { name: "Tent", variants: [{ weight: 1 }] }).gear;
    expect(a).toMatchObject({ favorite: false, purchase: "" });
    const b = mergeOrCreateGear([], { name: "Quilt", favorite: 1, purchase: "bogus", variants: [{ weight: 1 }] }).gear;
    expect(b).toMatchObject({ favorite: true, purchase: "" });
  });

  it("keeps the existing gear's favorite/purchase when merging", () => {
    const prev = [
      { id: "x", name: "Tent", itemType: "", categories: ["Shelter"], description: "", notes: "", favorite: true, purchase: "need", variants: [{ id: "v1", name: "Default", weight: 1200 }] }
    ];
    const { gears } = mergeOrCreateGear(prev, { name: "Tent", favorite: false, purchase: "owned", variants: [{ weight: 1300 }] });
    expect(gears[0]).toMatchObject({ favorite: true, purchase: "need" });
  });
});

describe("nextPurchase", () => {
  it("cycles none -> need -> owned -> none", () => {
    expect(nextPurchase("")).toBe("need");
    expect(nextPurchase("need")).toBe("owned");
    expect(nextPurchase("owned")).toBe("");
    expect(nextPurchase(undefined)).toBe("need");
  });
});
