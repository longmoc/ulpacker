import { parseNumber, normalizeWeightType, unitToGrams, textContent } from "./util.js";

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
      const name = (cols[idx.name] || "").trim();
      const description = (cols[idx.description] || "").trim();
      if (!name && !description) return null;

      const isWorn = isTruthyFlag(cols[idx.worn]);
      const isConsumable = isTruthyFlag(cols[idx.consumable]);

      return {
        name,
        description,
        category: (cols[idx.category] || "").trim(),
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
