// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import {
  parseCsvLine,
  extractVariantFromName,
  parseLighterpackCsv,
  parseLighterpackHtml,
  mapImportedEntry
} from "../import.js";

describe("parseCsvLine", () => {
  it("splits on commas and trims", () => {
    expect(parseCsvLine("a, b ,c")).toEqual(["a", "b", "c"]);
  });

  it("respects quoted fields containing commas", () => {
    expect(parseCsvLine('"Smith, Bob",10')).toEqual(["Smith, Bob", "10"]);
  });

  it("unescapes doubled quotes", () => {
    expect(parseCsvLine('"say ""hi""",x')).toEqual(['say "hi"', "x"]);
  });
});

describe("extractVariantFromName", () => {
  it("pulls a trailing parenthetical", () => {
    expect(extractVariantFromName("Backpack (55L)")).toBe("55L");
  });

  it("returns empty when there is no trailing group", () => {
    expect(extractVariantFromName("Backpack")).toBe("");
    expect(extractVariantFromName("(55L) Backpack")).toBe("");
  });
});

describe("parseLighterpackCsv", () => {
  const csv = [
    "Item Name,Category,Weight,Unit,Quantity,Worn,Consumable,Description",
    "Backpack (55L),Pack,1.1,kg,1,no,no,Main pack",
    "Trail Mix,Food,200,g,2,no,yes,Snacks",
    ",,,,,,,"
  ].join("\n");

  it("maps headers to fields and converts units to grams", () => {
    const out = parseLighterpackCsv(csv);
    expect(out).toHaveLength(2); // blank row dropped
    expect(out[0]).toMatchObject({
      name: "Backpack (55L)",
      category: "Pack",
      grams: 1100,
      quantity: 1,
      weightType: "base",
      variant: "55L"
    });
    expect(out[1]).toMatchObject({ grams: 200, quantity: 2, weightType: "consumable" });
  });

  it("returns [] for input without data rows", () => {
    expect(parseLighterpackCsv("just one line")).toEqual([]);
  });
});

describe("parseLighterpackHtml", () => {
  it("extracts the list title and items grouped by category", () => {
    const html = `
      <div class="lpListName">Weekend Trip</div>
      <div class="lpCategory">
        <div class="lpCategoryName">Shelter</div>
        <div class="lpItem">
          <div class="lpName">Tent</div>
          <div class="lpDescription">2P</div>
          <div class="lpWeightCell"><input class="lpMG" value="1200000" /></div>
          <div class="lpQtyCell">1</div>
          <span class="lpWorn lpActive"></span>
        </div>
      </div>`;
    const { title, items } = parseLighterpackHtml(html);
    expect(title).toBe("Weekend Trip");
    expect(items).toHaveLength(1);
    expect(items[0]).toMatchObject({
      name: "Tent",
      category: "Shelter",
      grams: 1200, // 1,200,000 mg -> 1200 g
      quantity: 1,
      weightType: "worn"
    });
  });
});

describe("mapImportedEntry", () => {
  const entry = { name: "Tent", description: "2P shelter", category: "Shelter", grams: 1200, quantity: 1, variant: "Green" };

  it("name_to_name keeps name and description", () => {
    const out = mapImportedEntry(entry, { mappingMode: "name_to_name", autoFillItemTypeFromCategory: true });
    expect(out).toMatchObject({ name: "Tent", description: "2P shelter", itemType: "Shelter" });
  });

  it("description_to_name swaps name/itemType and can source description from variant", () => {
    const out = mapImportedEntry(entry, {
      mappingMode: "description_to_name",
      autoFillItemTypeFromCategory: false,
      descriptionSource: "variant"
    });
    expect(out).toMatchObject({ name: "2P shelter", itemType: "Tent", description: "Green" });
  });
});
