import { parseNumber, normalizeWeightType, unitToGrams, textContent } from "./util.js";

// Cells starting with = + - @ can be executed as formulas by spreadsheet apps
// (CSV injection). Prefix them with a single quote — Excel's own "treat as
// text" convention — and strip that exact prefix again on import so our own
// round-trip stays clean.
function escapeFormula(s) {
  return /^[=+\-@]/.test(s) ? `'${s}` : s;
}

export function unescapeFormula(s) {
  return /^'[=+\-@]/.test(s) ? s.slice(1) : s;
}

function csvCell(value) {
  const s = escapeFormula(String(value ?? ""));
  return /[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

// Export pack rows to a LighterPack-compatible CSV (Item Name = itemType,
// desc = product name) so it round-trips with this app's default import mapping.
export function packToCsv(rows) {
  const header = ["Item Name", "Category", "desc", "qty", "weight", "unit", "url", "price", "worn", "consumable"];
  const lines = [header.map(csvCell).join(",")];
  for (const row of rows || []) {
    const type = normalizeWeightType(row?.weightType);
    lines.push(
      [
        row?.itemType || "",
        row?.category || "",
        row?.name || "",
        String(Math.max(0, Math.round(parseNumber(row?.quantity, 0)))),
        String(Math.max(0, Math.round(parseNumber(row?.weight, 0)))),
        "gram",
        "",
        "",
        type === "worn" ? "worn" : "",
        type === "consumable" ? "consumable" : ""
      ]
        .map(csvCell)
        .join(",")
    );
  }
  return lines.join("\n");
}

export function parseCsvLine(line) {
  const cols = [];
  let current = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (char === "," && !inQuotes) {
      cols.push(current.trim());
      current = "";
      continue;
    }
    current += char;
  }
  cols.push(current.trim());
  return cols;
}

// LighterPack stamps the literal word "Worn"/"Consumable" in those columns when
// checked (empty when not). Other exports may use yes/true/1. Treat any non-empty
// value as set unless it is an explicit negative token.
export function isTruthyFlag(value) {
  const v = String(value || "").trim().toLowerCase();
  if (!v) return false;
  return !["no", "false", "0", "n"].includes(v);
}

export function extractVariantFromName(name) {
  const source = (name || "").trim();
  const match = source.match(/\(([^)]+)\)\s*$/);
  return match ? match[1].trim() : "";
}

export function parseLighterpackCsv(text) {
  const lines = text.split(/\r?\n/).filter((line) => line.trim());
  if (lines.length < 2) return [];

  const headers = parseCsvLine(lines[0]).map((h) => h.toLowerCase());
  const idx = {
    name: headers.findIndex((h) => h.includes("name") || h.includes("item")),
    // LighterPack exports the description column as "desc"; also match "description".
    description: headers.findIndex((h) => h.includes("desc")),
    category: headers.findIndex((h) => h.includes("category")),
    qty: headers.findIndex((h) => h === "qty" || h.includes("quantity")),
    weight: headers.findIndex((h) => h.includes("weight")),
    unit: headers.findIndex((h) => h.includes("unit")),
    worn: headers.findIndex((h) => h.includes("worn")),
    consumable: headers.findIndex((h) => h.includes("consum"))
  };

  return lines
    .slice(1)
    .map(parseCsvLine)
    .map((cols) => {
      const name = unescapeFormula((cols[idx.name] || "").trim());
      const description = unescapeFormula((cols[idx.description] || "").trim());
      if (!name && !description) return null;

      const isWorn = isTruthyFlag(cols[idx.worn]);
      const isConsumable = isTruthyFlag(cols[idx.consumable]);

      return {
        name,
        description,
        category: unescapeFormula((cols[idx.category] || "").trim()),
        grams: Math.round(unitToGrams(cols[idx.weight], cols[idx.unit])),
        quantity: Math.max(0, parseNumber(cols[idx.qty], 1)),
        weightType: isWorn ? "worn" : isConsumable ? "consumable" : "base",
        variant: extractVariantFromName(name)
      };
    })
    .filter(Boolean);
}

export function parseLighterpackHtml(html) {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const title = textContent(doc.querySelector(".lpListName"), "LighterPack");
  const categories = [...doc.querySelectorAll(".lpCategory")];
  const items = categories.flatMap((categoryNode) => {
    const category = textContent(categoryNode.querySelector(".lpCategoryName"), "");
    return [...categoryNode.querySelectorAll(".lpItem")]
      .map((row) => {
        const name = textContent(row.querySelector(".lpName"), "");
        const description = textContent(row.querySelector(".lpDescription"), "");
        if (!name && !description) return null;

        const mg = parseNumber(row.querySelector(".lpWeightCell .lpMG")?.value, 0);
        const isWorn = Boolean(row.querySelector(".lpWorn.lpActive"));
        const isConsumable = Boolean(row.querySelector(".lpConsumable.lpActive"));

        return {
          name,
          description,
          category,
          grams: Math.round(mg / 1000),
          quantity: Math.max(0, parseNumber(textContent(row.querySelector(".lpQtyCell")), 1)),
          weightType: isWorn ? "worn" : isConsumable ? "consumable" : "base",
          variant: extractVariantFromName(name)
        };
      })
      .filter(Boolean);
  });
  return { title, items };
}

export function mapImportedEntry(entry, importConfig) {
  const originalName = (entry.name || "").trim();
  const originalDescription = (entry.description || "").trim();
  const category = (entry.category || "").trim();

  if (importConfig.mappingMode === "description_to_name") {
    return {
      name: originalDescription || originalName || "Unnamed",
      category,
      itemType: originalName || (importConfig.autoFillItemTypeFromCategory ? category : ""),
      description: importConfig.descriptionSource === "variant" ? (entry.variant || "") : "",
      grams: Math.max(0, parseNumber(entry.grams, 0)),
      quantity: Math.max(0, parseNumber(entry.quantity, 1)),
      weightType: normalizeWeightType(entry.weightType)
    };
  }

  return {
    name: originalName || originalDescription || "Unnamed",
    category,
    itemType: importConfig.autoFillItemTypeFromCategory ? category : "",
    description: originalDescription,
    grams: Math.max(0, parseNumber(entry.grams, 0)),
    quantity: Math.max(0, parseNumber(entry.quantity, 1)),
    weightType: normalizeWeightType(entry.weightType)
  };
}
