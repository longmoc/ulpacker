import { describe, it, expect } from "vitest";
import {
  parseNumber,
  normalizeWeightType,
  normalizeText,
  gramsToKg,
  reorder,
  mutatePackItemsForPack,
  unitToGrams
} from "../util.js";

describe("parseNumber", () => {
  it("parses finite numbers", () => {
    expect(parseNumber("42")).toBe(42);
    expect(parseNumber(3.5)).toBe(3.5);
  });

  it("returns the fallback for non-finite input", () => {
    expect(parseNumber("abc", 7)).toBe(7);
    expect(parseNumber(undefined, 1)).toBe(1);
    expect(parseNumber(NaN, 9)).toBe(9);
  });

  it("treats empty string as 0, not the fallback (known quirk)", () => {
    expect(parseNumber("", 5)).toBe(0);
  });
});

describe("normalizeWeightType", () => {
  it("keeps worn and consumable", () => {
    expect(normalizeWeightType("worn")).toBe("worn");
    expect(normalizeWeightType("consumable")).toBe("consumable");
  });

  it("falls back to base for anything else", () => {
    expect(normalizeWeightType("base")).toBe("base");
    expect(normalizeWeightType("garbage")).toBe("base");
    expect(normalizeWeightType(undefined)).toBe("base");
  });
});

describe("normalizeText", () => {
  it("trims and lowercases", () => {
    expect(normalizeText("  Foo Bar ")).toBe("foo bar");
    expect(normalizeText(null)).toBe("");
  });
});

describe("gramsToKg", () => {
  it("formats grams as kg with 2 decimals", () => {
    expect(gramsToKg(1234)).toBe("1.23 kg");
    expect(gramsToKg(0)).toBe("0.00 kg");
  });
});

describe("reorder", () => {
  it("moves an element from one index to another", () => {
    expect(reorder(["a", "b", "c"], 0, 2)).toEqual(["b", "c", "a"]);
  });

  it("returns the original array on out-of-range indices", () => {
    const arr = ["a", "b"];
    expect(reorder(arr, -1, 1)).toBe(arr);
    expect(reorder(arr, 0, 5)).toBe(arr);
  });
});

describe("mutatePackItemsForPack", () => {
  it("only applies the mutation to items of the target pack", () => {
    const items = [
      { id: 1, packId: "a" },
      { id: 2, packId: "b" },
      { id: 3, packId: "a" }
    ];
    const result = mutatePackItemsForPack(items, "a", (packItems) =>
      packItems.map((item) => ({ ...item, touched: true }))
    );
    expect(result.find((i) => i.id === 2).touched).toBeUndefined();
    expect(result.filter((i) => i.packId === "a").every((i) => i.touched)).toBe(true);
  });
});

describe("unitToGrams", () => {
  it("converts known units to grams", () => {
    expect(unitToGrams(1, "g")).toBe(1);
    expect(unitToGrams(1, "kg")).toBe(1000);
    expect(unitToGrams(1, "oz")).toBeCloseTo(28.3495, 4);
    expect(unitToGrams(1, "lb")).toBeCloseTo(453.592, 3);
  });

  it("treats unknown units as grams and 0 as 0", () => {
    expect(unitToGrams(5, "stone")).toBe(5);
    expect(unitToGrams(0, "kg")).toBe(0);
  });
});
