import { id, parseNumber, normalizeText } from "./util.js";

export function normalizeCategories(value) {
  const list = Array.isArray(value)
    ? value
    : String(value || "")
        .split(",")
        .map((item) => item.trim());
  const cleaned = list.filter(Boolean);
  return cleaned.length > 0 ? [...new Set(cleaned)] : ["Uncategorized"];
}

export function primaryCategory(gearOrCategories) {
  if (Array.isArray(gearOrCategories)) return normalizeCategories(gearOrCategories)[0];
  return normalizeCategories(gearOrCategories?.categories || gearOrCategories?.category || [])[0];
}

export function gearMergeKey(name, itemType) {
  return `${normalizeText(name)}||${normalizeText(itemType)}`;
}

export function normalizePurchase(value) {
  return value === "owned" || value === "need" ? value : "";
}

// Click-to-cycle order for the purchase control: none -> need -> owned -> none.
export function nextPurchase(current) {
  if (current === "need") return "owned";
  if (current === "owned") return "";
  return "need";
}

export function normalizeVariants(variants) {
  const raw = Array.isArray(variants) && variants.length > 0 ? variants : [{ weight: 0 }];

  // Dedupe by rounded weight, keeping the first occurrence's id + name so that
  // user-defined variant names (e.g. "40L") and references survive a round trip.
  const byWeight = new Map();
  for (const variant of raw) {
    const weight = Math.max(0, Math.round(parseNumber(variant?.weight, 0)));
    if (byWeight.has(weight)) continue;
    byWeight.set(weight, {
      id: variant?.id || id(),
      name: typeof variant?.name === "string" ? variant.name.trim() : "",
      weight,
      // Old data without a price is filled with 0 here (automatic migration).
      price: Math.max(0, parseNumber(variant?.price, 0))
    });
  }

  const ordered = [...byWeight.values()];
  const nonZero = ordered.filter((variant) => variant.weight > 0);
  const kept = nonZero.length > 0 ? nonZero : [ordered.find((variant) => variant.weight === 0)];

  return kept.map((variant, idx) => ({
    id: variant.id,
    name: variant.name || (idx === 0 ? "Default" : `Variant ${idx + 1}`),
    weight: variant.weight,
    price: variant.price
  }));
}

export function mergeVariants(existingVariants, incomingVariants) {
  return normalizeVariants([...(existingVariants || []), ...(incomingVariants || [])]);
}

export function mergeGears(gears) {
  const byKey = new Map();
  const idMap = new Map();

  for (const gear of gears) {
    const key = gearMergeKey(gear.name, gear.itemType);
    const normalized = {
      ...gear,
      categories: normalizeCategories(gear.categories || gear.category || []),
      variants: normalizeVariants(gear.variants || [])
    };

    if (!byKey.has(key)) {
      byKey.set(key, normalized);
      idMap.set(gear.id, normalized.id);
      continue;
    }

    const existing = byKey.get(key);
    existing.categories = normalizeCategories([...existing.categories, ...normalized.categories]);
    existing.variants = mergeVariants(existing.variants, normalized.variants);
    if (!existing.description && normalized.description) existing.description = normalized.description;
    if (!existing.notes && normalized.notes) existing.notes = normalized.notes;
    idMap.set(gear.id, existing.id);
  }

  return {
    gears: [...byKey.values()],
    idMap
  };
}

export function mergeOrCreateGear(prevGears, incoming) {
  const normalizedIncoming = {
    id: incoming.id || id(),
    name: (incoming.name || "").trim() || "Unnamed gear",
    categories: normalizeCategories(incoming.categories || incoming.category || []),
    itemType: (incoming.itemType || "").trim(),
    description: (incoming.description || "").trim(),
    notes: incoming.notes || "",
    favorite: Boolean(incoming.favorite),
    purchase: normalizePurchase(incoming.purchase),
    variants: normalizeVariants(incoming.variants || [])
  };

  const key = gearMergeKey(normalizedIncoming.name, normalizedIncoming.itemType);
  const index = prevGears.findIndex((gear) => gearMergeKey(gear.name, gear.itemType) === key);
  if (index === -1) {
    return { gears: [...prevGears, normalizedIncoming], gear: normalizedIncoming };
  }

  const existing = prevGears[index];
  const merged = {
    ...existing,
    categories: normalizeCategories([...(existing.categories || []), ...normalizedIncoming.categories]),
    description: existing.description || normalizedIncoming.description,
    notes: existing.notes || normalizedIncoming.notes,
    variants: mergeVariants(existing.variants, normalizedIncoming.variants)
  };

  const next = [...prevGears];
  next[index] = merged;
  return { gears: next, gear: merged };
}
