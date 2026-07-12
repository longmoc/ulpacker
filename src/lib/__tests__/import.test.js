// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import {
  parseCsvLine,
  extractVariantFromName,
  parseLighterpackCsv,
  parseLighterpackHtml,
  mapImportedEntry,
  packToCsv
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

  it("reads LighterPack's `desc` column (not just `description`)", () => {
    const lpCsv = [
      "Item Name,Category,desc,qty,weight,unit,url,price,worn,consumable",
      "Tent,Big 4,Durston X-Mid Pro 2,1,654,gram,,0,,",
      "Rain Coat,Packed Clothing,Montbell Versalite,1,143,gram,,0,Worn,"
    ].join("\n");
    const out = parseLighterpackCsv(lpCsv);
    expect(out[0].description).toBe("Durston X-Mid Pro 2");
    expect(out[1]).toMatchObject({ description: "Montbell Versalite", weightType: "worn", grams: 143 });

    // In description_to_name mode the product (desc) becomes the item name.
    const mapped = mapImportedEntry(out[0], { mappingMode: "description_to_name", autoFillItemTypeFromCategory: false });
    expect(mapped).toMatchObject({ name: "Durston X-Mid Pro 2", itemType: "Tent" });
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

describe("packToCsv", () => {
  it("writes a LighterPack-style header and maps itemType->Item Name, name->desc", () => {
    const csv = packToCsv([
      { itemType: "Tent", name: "Durston X-Mid Pro 2", category: "Shelter", quantity: 1, weight: 654, weightType: "base" },
      { itemType: "Food", name: "Trail dinner", category: "Food & Drink", quantity: 2, weight: 700, weightType: "consumable" },
      { itemType: "Shell", name: "Rain jacket", category: "Clothing", quantity: 1, weight: 180, weightType: "worn" }
    ]);
    const lines = csv.split("\n");
    expect(lines[0]).toBe("Item Name,Category,desc,qty,weight,unit,url,price,worn,consumable");
    expect(lines[1]).toBe("Tent,Shelter,Durston X-Mid Pro 2,1,654,gram,,,,");
    expect(lines[2]).toBe("Food,Food & Drink,Trail dinner,2,700,gram,,,,consumable");
    expect(lines[3]).toBe("Shell,Clothing,Rain jacket,1,180,gram,,,worn,");
  });

  it("quotes fields containing commas or quotes", () => {
    const csv = packToCsv([{ itemType: "Cables", name: 'USB-C, USB-A and "tips"', category: "Electronics", quantity: 1, weight: 20 }]);
    expect(csv.split("\n")[1]).toBe('Cables,Electronics,"USB-C, USB-A and ""tips""",1,20,gram,,,,');
  });

  it("round-trips through parseLighterpackCsv + description_to_name mapping", () => {
    const csv = packToCsv([{ itemType: "Tent", name: "X-Mid", category: "Shelter", quantity: 1, weight: 654, weightType: "base" }]);
    const entry = parseLighterpackCsv(csv)[0];
    const mapped = mapImportedEntry(entry, { mappingMode: "description_to_name", autoFillItemTypeFromCategory: false });
    expect(mapped).toMatchObject({ name: "X-Mid", itemType: "Tent" });
  });

  it("neutralises formula-looking cells (CSV injection) and round-trips them", () => {
    const csv = packToCsv([
      { itemType: "=HYPERLINK(\"http://evil\")", name: "+SUM(A1)", category: "@cmd", quantity: 1, weight: 10, weightType: "base" }
    ]);
    // Exported cells are prefixed with ' so spreadsheets treat them as text
    // (the first cell is additionally quote-wrapped because it contains ").
    const line = csv.split("\n")[1];
    expect(line.startsWith("\"'=HYPERLINK")).toBe(true);
    expect(line).toContain(",'@cmd,");
    expect(line).toContain("'+SUM(A1)");
    // Our own importer strips that exact prefix again.
    const entry = parseLighterpackCsv(csv)[0];
    expect(entry.name).toBe("=HYPERLINK(\"http://evil\")");
    expect(entry.description).toBe("+SUM(A1)");
    expect(entry.category).toBe("@cmd");
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
