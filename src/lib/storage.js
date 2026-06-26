import { id, parseNumber, normalizeWeightType } from "./util.js";
import { normalizeCategories, normalizeVariants, normalizePurchase, mergeGears, primaryCategory } from "./gear.js";

export const STORAGE_KEY = "ulpacker.v3";

export function eggSeed() {
  return {
    id: id(),
    name: "Egg",
    categories: ["Food"],
    itemType: "Fresh Food",
    description: "Chicken egg",
    notes: "EU medium class (53-63g), midpoint estimate 58g.",
    favorite: false,
    purchase: "",
    variants: [{ id: id(), name: "Default", weight: 58 }]
  };
}

export function ensurePackDefaults(data) {
  const packs = Array.isArray(data.packs) && data.packs.length > 0
    ? data.packs.map((pack) => ({
        id: pack.id || id(),
        name: pack.name || "Unnamed Pack",
        description: pack.description || "",
        createdAt: pack.createdAt || new Date().toISOString(),
        categoryOrder: Array.isArray(pack.categoryOrder)
          ? pack.categoryOrder.filter((c) => typeof c === "string")
          : []
      }))
    : [
        {
          id: id(),
          name: "My First Pack",
          description: "",
          createdAt: new Date().toISOString(),
          categoryOrder: []
        }
      ];

  const primaryPackId = packs[0].id;

  const packItems = Array.isArray(data.packItems)
    ? data.packItems
        .map((item) => ({
          id: item.id || id(),
          packId: item.packId || primaryPackId,
          gearId: item.gearId,
          variantId: item.variantId || "",
          category: item.category || "",
          quantity: Math.max(0, parseNumber(item.quantity, 1)),
          weight: item.weight,
          weightType: normalizeWeightType(item.weightType)
        }))
        .filter((item) => Boolean(item.gearId))
    : [];

  return { packs, packItems };
}

export function defaultData() {
  return {
    gears: [
      {
        id: id(),
        name: "Backpack",
        categories: ["Pack"],
        itemType: "",
        description: "",
        notes: "",
        favorite: false,
        purchase: "",
        variants: [
          { id: id(), name: "40L", weight: 920 },
          { id: id(), name: "55L", weight: 1100 }
        ]
      },
      {
        id: id(),
        name: "Rain jacket",
        categories: ["Clothing"],
        itemType: "",
        description: "",
        notes: "",
        favorite: false,
        purchase: "",
        variants: [{ id: id(), name: "Default", weight: 180 }]
      },
      eggSeed()
    ],
    packs: [
      {
        id: id(),
        name: "My First Pack",
        description: "",
        createdAt: new Date().toISOString(),
        categoryOrder: []
      }
    ],
    packItems: []
  };
}

// Validate + normalize a raw data object (from localStorage or an imported
// backup file) into the shape the app expects. Returns null when the input is
// not recognizable so callers can decide how to handle the failure.
export function normalizeData(parsed) {
  if (!parsed || !Array.isArray(parsed.gears)) return null;

  const parsedGears = parsed.gears
      .map((gear) => {
        if (!gear || typeof gear !== "object") return null;
        return {
          id: gear.id || id(),
          name: gear.name || "Unnamed gear",
          categories: normalizeCategories(gear.categories || gear.category || []),
          itemType: gear.itemType || "",
          description: gear.description || "",
          notes: gear.notes || "",
          favorite: Boolean(gear.favorite),
          purchase: normalizePurchase(gear.purchase),
          variants: normalizeVariants(gear.variants)
        };
      })
      .filter(Boolean);

    // The Egg seed only ships with `defaultData()` for brand-new users; we must
    // NOT re-inject it here, otherwise deleting it would silently come back on
    // the next load.
    const merged = mergeGears(parsedGears);
    const gears = merged.gears;
    const fullIdMap = merged.idMap;

    const withPackDefaults = ensurePackDefaults(parsed);
    const validGearIds = new Set(gears.map((gear) => gear.id));
    const validPackIds = new Set(withPackDefaults.packs.map((pack) => pack.id));

    const packItems = withPackDefaults.packItems
      .map((item) => {
        const remappedGearId = fullIdMap.get(item.gearId) || item.gearId;
        if (!validGearIds.has(remappedGearId)) return null;
        if (!validPackIds.has(item.packId)) return null;
        const gear = gears.find((g) => g.id === remappedGearId);
        const fallbackVariant = gear?.variants?.[0];
        return {
          ...item,
          gearId: remappedGearId,
          variantId:
            item.variantId && gear?.variants?.some((v) => v.id === item.variantId)
              ? item.variantId
              : fallbackVariant?.id || "",
          category: item.category || primaryCategory(gear),
          weight: Number.isFinite(Number(item.weight))
            ? Math.max(0, parseNumber(item.weight, 0))
            : Math.max(0, parseNumber(fallbackVariant?.weight, 0))
        };
      })
      .filter(Boolean);

  return {
    gears,
    packs: withPackDefaults.packs,
    packItems
  };
}

export function readStorage() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return defaultData();
    return normalizeData(JSON.parse(raw)) || defaultData();
  } catch {
    return defaultData();
  }
}
