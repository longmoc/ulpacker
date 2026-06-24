import React, { useEffect, useMemo, useState } from "react";
import { id, parseNumber, normalizeWeightType, normalizeText, gramsToKg, reorder, mutatePackItemsForPack, applyOrder } from "./lib/util.js";
import { normalizeCategories, primaryCategory, mergeOrCreateGear } from "./lib/gear.js";
import { parseLighterpackCsv, parseLighterpackHtml, mapImportedEntry } from "./lib/import.js";
import { buildPieSegments, describeDonutArc } from "./lib/chart.js";
import { STORAGE_KEY, readStorage, normalizeData } from "./lib/storage.js";
import logoUrl from "./logo.png";

function createEmptyDraft(category = "") {
  return {
    name: "",
    itemType: "",
    quantity: 1,
    weight: 0,
    weightType: "base",
    gearId: "",
    variantId: "",
    category
  };
}

function CategoryChipsInput({ categories, onChange, placeholder = "Type and press Enter" }) {
  const [input, setInput] = useState("");
  const tags = normalizeCategories(categories);

  function addTag(raw) {
    const trimmed = String(raw || "").trim();
    if (!trimmed) return;
    const lower = normalizeText(trimmed);
    if (tags.some((tag) => normalizeText(tag) === lower)) return;
    onChange([...tags, trimmed]);
  }

  function removeTag(tag) {
    const next = tags.filter((item) => item !== tag);
    onChange(next.length > 0 ? next : ["Uncategorized"]);
  }

  function handleKeyDown(e) {
    if (e.key === "Enter" || e.key === ",") {
      e.preventDefault();
      addTag(input);
      setInput("");
    }
    if (e.key === "Backspace" && !input && tags.length > 0) {
      removeTag(tags[tags.length - 1]);
    }
  }

  return (
    <div className="chips-input">
      <div className="chips-list">
        {tags.map((tag) => (
          <span key={tag} className="chip-tag">
            {tag}
            <button type="button" onClick={() => removeTag(tag)}>
              ×
            </button>
          </span>
        ))}
      </div>
      <input
        value={input}
        placeholder={placeholder}
        onChange={(e) => setInput(e.target.value)}
        onBlur={() => {
          addTag(input);
          setInput("");
        }}
        onKeyDown={handleKeyDown}
      />
    </div>
  );
}

function ConsumableIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M3 2v7c0 1.1.9 2 2 2h0a2 2 0 0 0 2-2V2" />
      <path d="M7 2v20" />
      <path d="M21 15V2a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3Zm0 0v7" />
    </svg>
  );
}

function WornIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="16"
      height="16"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M20.38 3.46 16 2a4 4 0 0 1-8 0L3.62 3.46a2 2 0 0 0-1.34 2.23l.58 3.47a1 1 0 0 0 .99.84H6v10c0 1.1.9 2 2 2h8a2 2 0 0 0 2-2V10h2.15a1 1 0 0 0 .99-.84l.58-3.47a2 2 0 0 0-1.34-2.23z" />
    </svg>
  );
}

function BackpackIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M5 10a5 5 0 0 1 5-5h4a5 5 0 0 1 5 5v9a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2z" />
      <path d="M9 5V4a3 3 0 0 1 6 0v1" />
      <path d="M8 11h8" />
      <path d="M9 21v-4a3 3 0 0 1 6 0v4" />
    </svg>
  );
}

function BoxIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z" />
      <path d="m3.3 7 8.7 5 8.7-5" />
      <path d="M12 22V12" />
    </svg>
  );
}

function RemoveItemIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M18 6 6 18" />
      <path d="m6 6 12 12" />
    </svg>
  );
}

function ExportIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M12 15V3" />
      <path d="m8 7 4-4 4 4" />
      <path d="M4 14v5a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5" />
    </svg>
  );
}

function ImportIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M12 3v12" />
      <path d="m8 11 4 4 4-4" />
      <path d="M4 14v5a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-5" />
    </svg>
  );
}

function CloudDownloadIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M4 14.899A7 7 0 1 1 15.71 8h1.79a4.5 4.5 0 0 1 2.5 8.242" />
      <path d="M12 12v9" />
      <path d="m8 17 4 4 4-4" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M3 6h18" />
      <path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" />
      <path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />
      <path d="M10 11v6" />
      <path d="M14 11v6" />
    </svg>
  );
}

function SettingsIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  );
}

export default function App() {
  const initial = readStorage();

  const [gears, setGears] = useState(initial.gears);
  const [packs, setPacks] = useState(initial.packs);
  const [packItems, setPackItems] = useState(initial.packItems);
  const [activePackId, setActivePackId] = useState(initial.packs[0]?.id || "");
  const [dragOverIndex, setDragOverIndex] = useState(null);

  const [newPack, setNewPack] = useState({ name: "", description: "" });
  const [newGear, setNewGear] = useState({
    name: "",
    categories: ["Uncategorized"],
    itemType: "",
    description: "",
    variantName: "Default",
    variantWeight: ""
  });

  const [importUrl, setImportUrl] = useState("");
  const [importStatus, setImportStatus] = useState("");
  const [importing, setImporting] = useState(false);
  const [importModal, setImportModal] = useState(null);
  const [csvStaged, setCsvStaged] = useState(null);
  const [view, setView] = useState("packs");
  const [chartHover, setChartHover] = useState(null);
  const [selectedCategory, setSelectedCategory] = useState(null);
  const [selectedWeightType, setSelectedWeightType] = useState(null);
  const [categoryDrafts, setCategoryDrafts] = useState({});
  const [libraryQuery, setLibraryQuery] = useState("");
  const [expandedGears, setExpandedGears] = useState({});
  const [addGearOpen, setAddGearOpen] = useState(false);
  const [addOpen, setAddOpen] = useState({});
  const [newCategories, setNewCategories] = useState([]);
  const [hideZeroQty, setHideZeroQty] = useState(() => {
    try {
      return Boolean(JSON.parse(localStorage.getItem("ulpacker.settings") || "{}").hideZeroQty);
    } catch {
      return false;
    }
  });
  const [libraryPackTarget, setLibraryPackTarget] = useState({});
  const [categoryDragSource, setCategoryDragSource] = useState(null);
  const [categoryDragOver, setCategoryDragOver] = useState(null);
  const [importConfig, setImportConfig] = useState({
    mappingMode: "description_to_name",
    autoFillItemTypeFromCategory: true,
    descriptionSource: "empty"
  });

  const activePack = packs.find((pack) => pack.id === activePackId) || packs[0] || null;

  useEffect(() => {
    if (!activePack && packs.length > 0) {
      setActivePackId(packs[0].id);
    }
  }, [packs, activePack]);

  useEffect(() => {
    setSelectedCategory(null);
    setSelectedWeightType(null);
    setNewCategories([]);
  }, [activePackId]);

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ gears, packs, packItems }));
  }, [gears, packs, packItems]);

  useEffect(() => {
    localStorage.setItem("ulpacker.settings", JSON.stringify({ hideZeroQty }));
  }, [hideZeroQty]);

  useEffect(() => {
    setPackItems((prev) => {
      const validPackIds = new Set(packs.map((pack) => pack.id));
      let changed = false;
      const next = prev
        .map((item) => {
          const gear = gears.find((g) => g.id === item.gearId);
          if (!gear || gear.variants.length === 0 || !validPackIds.has(item.packId)) {
            changed = true;
            return null;
          }
          const fallbackVariantId =
            item.variantId && gear.variants.some((v) => v.id === item.variantId)
              ? item.variantId
              : gear.variants[0].id;
          const fallbackCategory = item.category || primaryCategory(gear);
          const fallbackWeight = Number.isFinite(Number(item.weight))
            ? Math.max(0, parseNumber(item.weight, 0))
            : Math.max(0, parseNumber(gear.variants.find((v) => v.id === fallbackVariantId)?.weight, 0));
          if (fallbackVariantId !== item.variantId) {
            changed = true;
            return { ...item, variantId: fallbackVariantId, category: fallbackCategory, weight: fallbackWeight };
          }
          const normalized = normalizeWeightType(item.weightType);
          if (normalized !== item.weightType || fallbackWeight !== item.weight || fallbackCategory !== item.category) {
            changed = true;
            return { ...item, weightType: normalized, weight: fallbackWeight, category: fallbackCategory };
          }
          return item;
        })
        .filter(Boolean);

      return changed ? next : prev;
    });
  }, [gears, packs]);

  const activePackRows = useMemo(() => {
    if (!activePack) return [];
    return packItems
      .filter((item) => item.packId === activePack.id)
      .map((item) => {
        const gear = gears.find((g) => g.id === item.gearId);
        if (!gear) return null;
        return {
          ...item,
          gear,
          category: item.category || primaryCategory(gear),
          lineWeight: Math.max(0, Number(item.quantity || 0)) * Math.max(0, parseNumber(item.weight, 0))
        };
      })
      .filter(Boolean);
  }, [packItems, gears, activePack]);

  const carriedRows = activePackRows.filter((row) => Number(row.quantity) > 0);
  const totals = {
    total: carriedRows.reduce((sum, row) => sum + row.lineWeight, 0),
    base: carriedRows.filter((row) => row.weightType === "base").reduce((sum, row) => sum + row.lineWeight, 0),
    worn: carriedRows.filter((row) => row.weightType === "worn").reduce((sum, row) => sum + row.lineWeight, 0),
    consumable: carriedRows
      .filter((row) => row.weightType === "consumable")
      .reduce((sum, row) => sum + row.lineWeight, 0)
  };
  // Carried = what's actually in the pack on your back, i.e. everything except worn.
  totals.carried = totals.total - totals.worn;

  const categoryRows = useMemo(() => {
    const grouped = new Map();
    for (const row of carriedRows) {
      const key = row.category || primaryCategory(row.gear);
      grouped.set(key, (grouped.get(key) || 0) + row.lineWeight);
    }
    return [...grouped.entries()]
      .map(([category, weight]) => ({ category, weight }))
      .sort((a, b) => b.weight - a.weight);
  }, [carriedRows]);

  const pieSegments = buildPieSegments(categoryRows);
  const packGroups = useMemo(() => {
    const grouped = new Map();
    for (const row of activePackRows) {
      if (hideZeroQty && Number(row.quantity) <= 0) continue;
      if (selectedWeightType) {
        const type = normalizeWeightType(row.weightType);
        // "carried" = everything except worn; others match the exact type.
        if (selectedWeightType === "carried" ? type === "worn" : type !== selectedWeightType) continue;
      }
      const category = row.category || primaryCategory(row.gear);
      if (!grouped.has(category)) {
        grouped.set(category, { category, rows: [], totalWeight: 0, gearIds: new Set() });
      }
      const group = grouped.get(category);
      group.rows.push(row);
      group.totalWeight += row.lineWeight;
      group.gearIds.add(row.gear.id);
    }
    // Manual category order (per pack); new categories fall to the end.
    const ordered = applyOrder([...grouped.keys()], activePack?.categoryOrder || []);
    // Empty categories the user just created (no items yet).
    for (const name of newCategories) {
      if (!grouped.has(name)) {
        grouped.set(name, { category: name, rows: [], totalWeight: 0, gearIds: new Set() });
        ordered.push(name);
      }
    }
    if (ordered.length === 0) {
      return [{ category: "Uncategorized", rows: [], totalWeight: 0, gearIds: new Set() }];
    }
    return ordered.map((c) => grouped.get(c));
  }, [activePackRows, activePack, hideZeroQty, selectedWeightType, newCategories]);

  // Only treat the filter as active while its category still exists in the pack.
  const activeFilter =
    selectedCategory && packGroups.some((group) => group.category === selectedCategory)
      ? selectedCategory
      : null;
  const visibleGroups = activeFilter
    ? packGroups.filter((group) => group.category === activeFilter)
    : packGroups;

  function toggleCategoryFilter(category) {
    setSelectedCategory((prev) => (prev === category ? null : category));
  }

  function toggleWeightTypeFilter(type) {
    setSelectedWeightType((prev) => (prev === type ? null : type));
  }
  const filteredGears = useMemo(() => {
    const q = normalizeText(libraryQuery);
    if (!q) return gears;
    return gears.filter((gear) => {
      const categories = (gear.categories || []).join(" ");
      return normalizeText(`${gear.name} ${gear.itemType} ${gear.description} ${categories}`).includes(q);
    });
  }, [gears, libraryQuery]);

  function createPack(e) {
    e.preventDefault();
    if (!newPack.name.trim()) return;
    const pack = {
      id: id(),
      name: newPack.name.trim(),
      description: newPack.description.trim(),
      createdAt: new Date().toISOString(),
      categoryOrder: []
    };
    setPacks((prev) => [pack, ...prev]);
    setActivePackId(pack.id);
    setNewPack({ name: "", description: "" });
  }

  function updateActivePack(patch) {
    if (!activePack) return;
    setPacks((prev) => prev.map((pack) => (pack.id === activePack.id ? { ...pack, ...patch } : pack)));
  }

  function deleteActivePack() {
    if (!activePack) return;
    if (!window.confirm(`Delete pack "${activePack.name}"? Its items will be removed.`)) return;
    const targetId = activePack.id;
    setPackItems((prev) => prev.filter((item) => item.packId !== targetId));
    const remaining = packs.filter((pack) => pack.id !== targetId);
    if (remaining.length === 0) {
      // Deleting the last pack resets to a fresh empty one instead of leaving
      // the app with no pack at all.
      const fresh = { id: id(), name: "My First Pack", description: "", createdAt: new Date().toISOString(), categoryOrder: [] };
      setPacks([fresh]);
      setActivePackId(fresh.id);
      return;
    }
    setPacks(remaining);
    setActivePackId(remaining[0].id);
  }

  function renameGroupCategory(oldCategory, nextCategory) {
    const trimmed = (nextCategory || "").trim() || "Uncategorized";
    const targetGroup = packGroups.find((group) => group.category === oldCategory);
    if (!targetGroup) return;
    const ids = targetGroup.gearIds;
    setPackItems((prev) =>
      prev.map((item) =>
        item.packId === activePack?.id && item.category === oldCategory ? { ...item, category: trimmed } : item
      )
    );
    setGears((prev) =>
      prev.map((gear) =>
        ids.has(gear.id) ? { ...gear, categories: normalizeCategories([...(gear.categories || []), trimmed]) } : gear
      )
    );
    // Keep the manual order in sync so the renamed category stays in place.
    if (activePack?.categoryOrder?.length) {
      const next = activePack.categoryOrder.map((c) => (c === oldCategory ? trimmed : c));
      updateActivePack({ categoryOrder: [...new Set(next)] });
    }
    // Track renames of empty (not-yet-used) categories too.
    setNewCategories((prev) =>
      prev.includes(oldCategory) ? [...new Set(prev.map((c) => (c === oldCategory ? trimmed : c)))] : prev
    );
  }

  function addCategory() {
    if (!activePack) return;
    const name = (window.prompt("New category name") || "").trim();
    if (!name) return;
    setNewCategories((prev) => (prev.includes(name) ? prev : [...prev, name]));
    setAddOpen((prev) => ({ ...prev, [name]: true }));
  }

  function moveCategory(from, target) {
    if (!activePack || from === target) return;
    const order = packGroups.map((group) => group.category);
    const fromIdx = order.indexOf(from);
    const targetIdx = order.indexOf(target);
    if (fromIdx === -1 || targetIdx === -1) return;
    const next = [...order];
    next.splice(fromIdx, 1);
    next.splice(targetIdx, 0, from);
    updateActivePack({ categoryOrder: next });
  }

  function onCategoryDrop(e, targetCategory) {
    const payload = e.dataTransfer.getData("application/json");
    if (!payload) return;
    let data;
    try {
      data = JSON.parse(payload);
    } catch {
      return;
    }
    if (data.type !== "category") return; // let item/library drops bubble to the column
    e.stopPropagation();
    moveCategory(data.category, targetCategory);
    setCategoryDragSource(null);
    setCategoryDragOver(null);
  }

  function toggleWeightFlag(itemId, targetType) {
    setPackItems((prev) =>
      prev.map((item) => {
        if (item.id !== itemId) return item;
        const current = normalizeWeightType(item.weightType);
        return { ...item, weightType: current === targetType ? "base" : targetType };
      })
    );
  }

  function getDraft(category) {
    return categoryDrafts[category] || createEmptyDraft(category);
  }

  function updateDraft(category, patch) {
    setCategoryDrafts((prev) => {
      const current = prev[category] || createEmptyDraft(category);
      return { ...prev, [category]: { ...current, ...patch, category } };
    });
  }

  function resetDraft(category) {
    setCategoryDrafts((prev) => ({ ...prev, [category]: createEmptyDraft(category) }));
  }

  function matchingGears(keyword) {
    const lower = (keyword || "").trim().toLowerCase();
    if (!lower) return [];
    return gears
      .filter((gear) => gear.name.toLowerCase().includes(lower))
      .slice(0, 5);
  }

  function applyGearSuggestion(category, gearId) {
    const gear = gears.find((item) => item.id === gearId);
    if (!gear) return;
    const variant = gear.variants[0];
    updateDraft(category, {
      gearId: gear.id,
      variantId: variant?.id || "",
      name: gear.name,
      itemType: gear.itemType || "",
      weight: Math.max(0, parseNumber(variant?.weight, 0))
    });
  }

  function applyDraftVariant(category, variantId) {
    const draft = getDraft(category);
    const gear = gears.find((item) => item.id === draft.gearId);
    if (!gear) return;
    const variant = gear.variants.find((item) => item.id === variantId);
    updateDraft(category, {
      variantId,
      weight: Math.max(0, parseNumber(variant?.weight, draft.weight))
    });
  }

  function addItemFromDraft(category) {
    if (!activePack) return;
    const normalizedCategory = (category || "").trim() || "Uncategorized";
    const draft = getDraft(normalizedCategory);
    const itemName = (draft.name || "").trim();
    if (!itemName) return;

    const merged = mergeOrCreateGear(gears, {
      id: draft.gearId || id(),
      name: itemName,
      categories: [normalizedCategory],
      itemType: (draft.itemType || "").trim(),
      description: "",
      variants: [{ id: draft.variantId || id(), name: "Default", weight: Math.max(0, parseNumber(draft.weight, 0)) }]
    });
    const gear = merged.gear;
    setGears(merged.gears);

    const variantId = gear.variants.find((variant) => variant.id === draft.variantId)?.id || gear.variants[0]?.id || "";

    const item = {
      id: id(),
      packId: activePack.id,
      gearId: gear.id,
      variantId,
      category: normalizedCategory,
      quantity: Math.max(0, parseNumber(draft.quantity, 1)),
      weight: Math.max(0, parseNumber(draft.weight, 0)),
      weightType: normalizeWeightType(draft.weightType)
    };
    setPackItems((prev) => [...prev, item]);
    resetDraft(normalizedCategory);
  }

  function addGear(e) {
    e.preventDefault();
    if (!newGear.name.trim()) return;
    const weight = Math.max(0, parseNumber(newGear.variantWeight, 0));
    setGears((prev) =>
      mergeOrCreateGear(prev, {
        id: id(),
        name: newGear.name.trim(),
        categories: normalizeCategories(newGear.categories),
        itemType: newGear.itemType.trim(),
        description: newGear.description.trim(),
        notes: "",
        variants: [{ id: id(), name: newGear.variantName.trim() || "Default", weight }]
      }).gears
    );
    setNewGear({
      name: "",
      categories: ["Uncategorized"],
      itemType: "",
      description: "",
      variantName: "Default",
      variantWeight: ""
    });
  }

  function toggleGearExpanded(gearId) {
    setExpandedGears((prev) => ({ ...prev, [gearId]: !prev[gearId] }));
  }

  function removeGearFromLibrary(gearId) {
    setGears((prev) => prev.filter((gear) => gear.id !== gearId));
    setPackItems((prev) => prev.filter((item) => item.gearId !== gearId));
    setExpandedGears((prev) => {
      const next = { ...prev };
      delete next[gearId];
      return next;
    });
    setLibraryPackTarget((prev) => {
      const next = { ...prev };
      delete next[gearId];
      return next;
    });
  }

  function updateGear(gearId, patch) {
    setGears((prev) => prev.map((gear) => (gear.id === gearId ? { ...gear, ...patch } : gear)));
  }

  function addVariant(gearId) {
    setGears((prev) =>
      prev.map((gear) =>
        gear.id === gearId
          ? {
              ...gear,
              variants: [
                ...gear.variants,
                { id: id(), name: `Variant ${gear.variants.length + 1}`, weight: 0 }
              ]
            }
          : gear
      )
    );
  }

  function updateVariant(gearId, variantId, patch) {
    setGears((prev) =>
      prev.map((gear) =>
        gear.id === gearId
          ? {
              ...gear,
              variants: gear.variants.map((variant) =>
                variant.id === variantId ? { ...variant, ...patch } : variant
              )
            }
          : gear
      )
    );
  }

  function removeVariant(gearId, variantId) {
    setGears((prev) =>
      prev.map((gear) => {
        if (gear.id !== gearId || gear.variants.length <= 1) return gear;
        return {
          ...gear,
          variants: gear.variants.filter((variant) => variant.id !== variantId)
        };
      })
    );
  }

  function addToPack(gearId, insertIndex = null) {
    if (!activePack) return;
    const gear = gears.find((item) => item.id === gearId);
    if (!gear || gear.variants.length === 0) return;

    setPackItems((prev) =>
      mutatePackItemsForPack(prev, activePack.id, (items) => {
        const nextItem = {
          id: id(),
          packId: activePack.id,
          gearId,
          variantId: gear.variants[0].id,
          category: primaryCategory(gear),
          quantity: 1,
          weight: Math.max(0, parseNumber(gear.variants[0]?.weight, 0)),
          weightType: "base"
        };
        if (insertIndex === null || insertIndex < 0 || insertIndex > items.length - 1) {
          return [...items, nextItem];
        }
        const next = [...items];
        next.splice(insertIndex, 0, nextItem);
        return next;
      })
    );
  }

  function addToSpecificPack(gearId, packId) {
    const target = packs.find((pack) => pack.id === packId);
    if (!target) return;
    const gear = gears.find((item) => item.id === gearId);
    if (!gear || gear.variants.length === 0) return;
    const newItem = {
      id: id(),
      packId: target.id,
      gearId,
      variantId: gear.variants[0].id,
      category: primaryCategory(gear),
      quantity: 1,
      weight: Math.max(0, parseNumber(gear.variants[0]?.weight, 0)),
      weightType: "base"
    };
    setPackItems((prev) => [...prev, newItem]);
  }

  function onPackDrop(e) {
    e.preventDefault();
    if (!activePack) return;
    const payload = e.dataTransfer.getData("application/json");
    if (!payload) return;

    try {
      const data = JSON.parse(payload);
      if (data.type === "library") {
        addToPack(data.gearId, dragOverIndex);
      }

      if (data.type === "pack") {
        const fromIndex = activePackRows.findIndex((row) => row.id === data.itemId);
        if (fromIndex === -1 || dragOverIndex === null) return;

        setPackItems((prev) =>
          mutatePackItemsForPack(prev, activePack.id, (items) => reorder(items, fromIndex, dragOverIndex))
        );
      }
    } catch {
      return;
    } finally {
      setDragOverIndex(null);
    }
  }

  function importEntries(entries, sourceLabel) {
    if (!activePack) {
      setImportStatus("Create a pack before importing.");
      return;
    }

    if (!entries.length) {
      setImportStatus("No data found to import.");
      return;
    }

    const mappedEntries = entries.map((entry) => mapImportedEntry(entry, importConfig));
    let nextGears = gears.map((gear) => ({ ...gear, variants: [...gear.variants], categories: [...(gear.categories || [])] }));
    const importedPackItems = [];

    for (const entry of mappedEntries) {
      const name = (entry.name || "").trim();
      if (!name) continue;

      const merged = mergeOrCreateGear(nextGears, {
        id: id(),
        name,
        categories: normalizeCategories(entry.category || []),
        itemType: (entry.itemType || "").trim(),
        description: (entry.description || "").trim(),
        notes: sourceLabel || "",
        variants: [{ id: id(), name: "Imported", weight: Math.max(0, parseNumber(entry.grams, 0)) }]
      });
      nextGears = merged.gears;
      const gear = merged.gear;
      const desiredWeight = Math.max(0, parseNumber(entry.grams, 0));
      const variant = gear.variants.find((v) => Math.round(v.weight) === Math.round(desiredWeight)) || gear.variants[0];

      importedPackItems.push({
        id: id(),
        packId: activePack.id,
        gearId: gear.id,
        variantId: variant.id,
        category: normalizeCategories(entry.category || [])[0],
        quantity: entry.quantity,
        weight: desiredWeight,
        weightType: normalizeWeightType(entry.weightType)
      });
    }

    setGears(nextGears);
    setPackItems((prev) => [...prev, ...importedPackItems]);
    setImportStatus(`Imported ${importedPackItems.length} items to ${activePack.name}.`);
    setImportModal(null);
  }

  async function handleImportUrl(e) {
    e.preventDefault();
    if (!importUrl.trim()) return;

    setImporting(true);
    setImportStatus("");

    try {
      const query = new URLSearchParams({ url: importUrl.trim() });
      const response = await fetch(`/api/lighterpack?${query.toString()}`);
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(payload?.error || "Cannot fetch URL.");
      }
      const parsed = parseLighterpackHtml(payload.html || "");
      importEntries(parsed.items, parsed.title);
    } catch (error) {
      setImportStatus(error.message || "Import failed.");
    } finally {
      setImporting(false);
    }
  }

  async function handleCsvFile(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    try {
      const entries = parseLighterpackCsv(await file.text());
      if (!entries.length) {
        setImportStatus("No data found in the CSV file.");
        setCsvStaged(null);
        return;
      }
      setCsvStaged({ entries, fileName: file.name });
      setImportStatus("");
    } catch {
      setImportStatus("Could not read the CSV file.");
    } finally {
      e.target.value = "";
    }
  }

  function confirmCsvImport() {
    if (!csvStaged) return;
    importEntries(csvStaged.entries, `CSV: ${csvStaged.fileName}`);
    setCsvStaged(null);
  }

  function openImport(kind) {
    setImportStatus("");
    setCsvStaged(null);
    setImportModal(kind);
  }

  function closeImportModal() {
    setImportModal(null);
    setCsvStaged(null);
    setImportStatus("");
  }

  function exportBackup() {
    const blob = new Blob([JSON.stringify({ gears, packs, packItems }, null, 2)], {
      type: "application/json"
    });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `ulpacker-backup-${new Date().toISOString().slice(0, 10)}.json`;
    link.click();
    URL.revokeObjectURL(url);
  }

  async function importBackup(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    try {
      const data = normalizeData(JSON.parse(await file.text()));
      if (!data) {
        window.alert("Invalid backup file.");
        return;
      }
      if (!window.confirm("Replace all current gear and packs with the data from this file?")) return;
      setGears(data.gears);
      setPacks(data.packs);
      setPackItems(data.packItems);
      setActivePackId(data.packs[0]?.id || "");
    } catch {
      window.alert("Could not read the backup file.");
    } finally {
      e.target.value = "";
    }
  }

  return (
    <div className="app">
      <header className="topbar">
        <img className="brand-logo" src={logoUrl} alt="ULPacker" />
        <div className="topbar-row">
          <div className="view-tabs">
            <button
              type="button"
              className={view === "packs" ? "active" : ""}
              onClick={() => setView("packs")}
            >
              Packs
            </button>
            <button
              type="button"
              className={view === "library" ? "active" : ""}
              onClick={() => setView("library")}
            >
              Gear Library
            </button>
          </div>
          <div className="data-tools">
            <div className="menu">
              <button type="button" className="menu-trigger">
                <ExportIcon />
                Export
              </button>
              <div className="menu-list">
                <button type="button" onClick={exportBackup}>
                  Backup to JSON
                </button>
              </div>
            </div>
            <div className="menu">
              <button type="button" className="menu-trigger">
                <ImportIcon />
                Import
              </button>
              <div className="menu-list">
                <label className="menu-file">
                  Restore from JSON
                  <input type="file" accept=".json,application/json" onChange={importBackup} />
                </label>
              </div>
            </div>
            <div className="menu">
              <button type="button" className="menu-trigger">
                <SettingsIcon />
                Settings
              </button>
              <div className="menu-list settings-menu">
                <label className="menu-check">
                  <input
                    type="checkbox"
                    checked={!hideZeroQty}
                    onChange={(e) => setHideZeroQty(!e.target.checked)}
                  />
                  Show items with quantity 0
                </label>
              </div>
            </div>
          </div>
        </div>
      </header>

      <main className={`dashboard ${view === "library" ? "library-layout" : ""}`}>
        {view === "packs" && (
        <aside className="panel packs-panel">
          <div className="panel-head">
            <h2>Packs</h2>
            <span>{packs.length} total</span>
          </div>

          <form className="new-pack-form" onSubmit={createPack}>
            <input
              placeholder="Pack name"
              value={newPack.name}
              onChange={(e) => setNewPack((prev) => ({ ...prev, name: e.target.value }))}
            />
            <input
              placeholder="Short description"
              value={newPack.description}
              onChange={(e) => setNewPack((prev) => ({ ...prev, description: e.target.value }))}
            />
            <button type="submit">Create Pack</button>
          </form>

          <div className="pack-cards">
            {packs.map((pack) => {
              const packWeight = packItems
                .filter((item) => item.packId === pack.id)
                .reduce((sum, item) => {
                  return (
                    sum +
                    Math.max(0, parseNumber(item.quantity, 0)) * Math.max(0, parseNumber(item.weight, 0))
                  );
                }, 0);

              return (
                <button
                  type="button"
                  key={pack.id}
                  className={`pack-card ${activePack?.id === pack.id ? "active" : ""}`}
                  onClick={() => setActivePackId(pack.id)}
                >
                  <strong>{pack.name}</strong>
                  <small>{pack.description || "No description"}</small>
                  <span>{gramsToKg(packWeight)}</span>
                </button>
              );
            })}
          </div>
        </aside>
        )}

        <section className="panel workspace">
          {view === "library" && (
            <>
              <div className="panel-head">
                <h2>Gear Library</h2>
                <span>{gears.length} items</span>
              </div>

              <section className="library-create">
                <button
                  type="button"
                  className="collapsible-head"
                  onClick={() => setAddGearOpen((open) => !open)}
                  aria-expanded={addGearOpen}
                >
                  <span>Add New Gear</span>
                  <span className="chev">{addGearOpen ? "▲" : "▼"}</span>
                </button>
                {addGearOpen && (
                <form className="new-gear-form" onSubmit={addGear}>
                  <label>
                    <span>Name</span>
                    <input
                      value={newGear.name}
                      onChange={(e) => setNewGear((prev) => ({ ...prev, name: e.target.value }))}
                    />
                  </label>
                  <label>
                    <span>Categories</span>
                    <CategoryChipsInput
                      categories={newGear.categories}
                      onChange={(next) => setNewGear((prev) => ({ ...prev, categories: next }))}
                    />
                  </label>
                  <label>
                    <span>Item Type</span>
                    <input
                      value={newGear.itemType}
                      onChange={(e) => setNewGear((prev) => ({ ...prev, itemType: e.target.value }))}
                    />
                  </label>
                  <label>
                    <span>Description</span>
                    <input
                      value={newGear.description}
                      onChange={(e) => setNewGear((prev) => ({ ...prev, description: e.target.value }))}
                    />
                  </label>
                  <label>
                    <span>Default Variant</span>
                    <input
                      value={newGear.variantName}
                      onChange={(e) => setNewGear((prev) => ({ ...prev, variantName: e.target.value }))}
                    />
                  </label>
                  <label>
                    <span>Weight (g)</span>
                    <input
                      type="number"
                      min="0"
                      value={newGear.variantWeight}
                      onChange={(e) => setNewGear((prev) => ({ ...prev, variantWeight: e.target.value }))}
                    />
                  </label>
                  <button type="submit">Add Gear</button>
                </form>
                )}
              </section>

              <section className="library-list">
                <div className="library-toolbar">
                  <input
                    value={libraryQuery}
                    onChange={(e) => setLibraryQuery(e.target.value)}
                    placeholder="Search by name, category, type"
                  />
                </div>
                <div className="library-table-head">
                  <span>Name</span>
                  <span>Item Type</span>
                  <span>Description</span>
                  <span>Categories</span>
                  <span>Variants</span>
                  <span />
                </div>
                <div className="gear-list compact">
                  {filteredGears.map((gear) => (
                    <article
                      key={gear.id}
                      className="gear-row"
                      draggable
                      onDragStart={(e) =>
                        e.dataTransfer.setData(
                          "application/json",
                          JSON.stringify({ type: "library", gearId: gear.id })
                        )
                      }
                    >
                      <input
                        className="gear-cell-name"
                        placeholder="Name"
                        value={gear.name}
                        onChange={(e) => updateGear(gear.id, { name: e.target.value })}
                      />
                      <input
                        placeholder="Item type"
                        value={gear.itemType}
                        onChange={(e) => updateGear(gear.id, { itemType: e.target.value })}
                      />
                      <input
                        placeholder="Description"
                        value={gear.description}
                        onChange={(e) => updateGear(gear.id, { description: e.target.value })}
                      />
                      <CategoryChipsInput
                        categories={gear.categories}
                        onChange={(next) => updateGear(gear.id, { categories: next })}
                        placeholder="Add category"
                      />
                      <button type="button" className="variant-toggle" onClick={() => toggleGearExpanded(gear.id)}>
                        {gear.variants.length} {gear.variants.length === 1 ? "variant" : "variants"}
                      </button>
                      <div className="library-actions">
                        <select
                          value={libraryPackTarget[gear.id] || activePackId || packs[0]?.id || ""}
                          onChange={(e) =>
                            setLibraryPackTarget((prev) => ({ ...prev, [gear.id]: e.target.value }))
                          }
                        >
                          {packs.map((pack) => (
                            <option key={pack.id} value={pack.id}>
                              {pack.name}
                            </option>
                          ))}
                        </select>
                        <button
                          type="button"
                          className="add-to-pack"
                          onClick={() =>
                            addToSpecificPack(
                              gear.id,
                              libraryPackTarget[gear.id] || activePackId || packs[0]?.id || ""
                            )
                          }
                        >
                          Add to Pack
                        </button>
                        <button
                          type="button"
                          className="danger icon-only"
                          title="Delete gear"
                          aria-label="Delete gear"
                          onClick={() => {
                            if (
                              !window.confirm(
                                `Delete "${gear.name}" from the library? It will also be removed from every pack.`
                              )
                            )
                              return;
                            removeGearFromLibrary(gear.id);
                          }}
                        >
                          <TrashIcon />
                        </button>
                      </div>

                      {expandedGears[gear.id] && (
                        <div className="variant-editor">
                          {gear.variants.map((variant) => (
                            <div className="variant-row compact" key={variant.id}>
                              <input
                                value={variant.name}
                                onChange={(e) => updateVariant(gear.id, variant.id, { name: e.target.value })}
                              />
                              <input
                                type="number"
                                min="0"
                                value={variant.weight}
                                onChange={(e) =>
                                  updateVariant(gear.id, variant.id, {
                                    weight: Math.max(0, parseNumber(e.target.value, 0))
                                  })
                                }
                              />
                              <span>g</span>
                              <button
                                type="button"
                                disabled={gear.variants.length <= 1}
                                onClick={() => removeVariant(gear.id, variant.id)}
                              >
                                Remove
                              </button>
                            </div>
                          ))}
                          <button type="button" onClick={() => addVariant(gear.id)}>
                            + Variant
                          </button>
                        </div>
                      )}
                    </article>
                  ))}
                </div>
              </section>
            </>
          )}

          {view === "packs" && (
            <>
              {!activePack && <p>Create a pack to start.</p>}

              {activePack && (
                <>
              <div className="workspace-head">
                <input
                  className="pack-name-input"
                  value={activePack.name}
                  onChange={(e) => updateActivePack({ name: e.target.value })}
                />
                <input
                  className="pack-desc-input"
                  value={activePack.description}
                  onChange={(e) => updateActivePack({ description: e.target.value })}
                  placeholder="Pack description"
                />
                <div className="workspace-actions">
                  <div className="menu">
                    <button type="button" className="menu-trigger">
                      <CloudDownloadIcon />
                      Import Pack
                    </button>
                    <div className="menu-list">
                      <button type="button" onClick={() => openImport("url")}>
                        From URL
                      </button>
                      <button type="button" onClick={() => openImport("csv")}>
                        From CSV file
                      </button>
                    </div>
                  </div>
                  <button type="button" className="action-danger" onClick={deleteActivePack}>
                    <TrashIcon />
                    Delete Pack
                  </button>
                </div>
              </div>

              <div className="summary-grid">
                <button
                  type="button"
                  className={`summary-card summary-card-btn ${selectedWeightType === "carried" ? "selected" : ""}`}
                  onClick={() => toggleWeightTypeFilter("carried")}
                >
                  <small>
                    <BackpackIcon /> Carried
                  </small>
                  <strong>{gramsToKg(totals.carried)}</strong>
                </button>
                <button
                  type="button"
                  className={`summary-card summary-card-btn ${selectedWeightType === "base" ? "selected" : ""}`}
                  onClick={() => toggleWeightTypeFilter("base")}
                >
                  <small>
                    <BoxIcon /> Base
                  </small>
                  <strong>{gramsToKg(totals.base)}</strong>
                </button>
                <button
                  type="button"
                  className={`summary-card summary-card-btn ${selectedWeightType === "consumable" ? "selected" : ""}`}
                  onClick={() => toggleWeightTypeFilter("consumable")}
                >
                  <small>
                    <ConsumableIcon /> Consumable
                  </small>
                  <strong>{gramsToKg(totals.consumable)}</strong>
                </button>
                <button
                  type="button"
                  className={`summary-card summary-card-btn ${selectedWeightType === "worn" ? "selected" : ""}`}
                  onClick={() => toggleWeightTypeFilter("worn")}
                >
                  <small>
                    <WornIcon /> Worn
                  </small>
                  <strong>{gramsToKg(totals.worn)}</strong>
                </button>
                <div className="summary-card">
                  <small>Total</small>
                  <strong>{gramsToKg(totals.total)}</strong>
                </div>
              </div>

              <section className="analytics">
                <div className="pie-wrap">
                  <svg className="pie-svg" viewBox="0 0 220 220" role="img" aria-label="Weight by category">
                    {pieSegments.length === 0 && (
                      <circle cx="110" cy="110" r="78" fill="none" stroke="#dbe3ea" strokeWidth="56" />
                    )}
                    {pieSegments.map((seg) => {
                      const startDeg = (seg.from / 100) * 360;
                      const endDeg = (seg.to / 100) * 360;
                      return (
                        <path
                          key={seg.category}
                          className={`pie-segment${activeFilter === seg.category ? " selected" : ""}${
                            activeFilter && activeFilter !== seg.category ? " dimmed" : ""
                          }`}
                          d={describeDonutArc(110, 110, 105, 52, startDeg, endDeg)}
                          fill={seg.color}
                          onClick={() => toggleCategoryFilter(seg.category)}
                          onMouseEnter={(e) => {
                            const rect = e.currentTarget.ownerSVGElement.getBoundingClientRect();
                            setChartHover({
                              ...seg,
                              x: e.clientX - rect.left,
                              y: e.clientY - rect.top
                            });
                          }}
                          onMouseMove={(e) => {
                            const rect = e.currentTarget.ownerSVGElement.getBoundingClientRect();
                            setChartHover((prev) =>
                              prev
                                ? {
                                    ...prev,
                                    x: e.clientX - rect.left,
                                    y: e.clientY - rect.top
                                  }
                                : null
                            );
                          }}
                          onMouseLeave={() => setChartHover(null)}
                        />
                      );
                    })}
                  </svg>
                  {chartHover && (
                    <div className="chart-tooltip" style={{ left: chartHover.x + 8, top: chartHover.y - 10 }}>
                      {chartHover.category}: {gramsToKg(chartHover.weight)} ({chartHover.percent.toFixed(1)}%)
                    </div>
                  )}
                </div>
                <div className="legend">
                  <h3>Category breakdown</h3>
                  {pieSegments.length === 0 && <p className="hint">No carried items yet.</p>}
                  <div className="legend-table">
                    <div className="legend-table-head">
                      <span>Category</span>
                      <span>Weight</span>
                      <span>%</span>
                    </div>
                    {pieSegments.map((seg) => (
                      <button
                        type="button"
                        key={seg.category}
                        className={`legend-row ${activeFilter === seg.category ? "selected" : ""}`}
                        onClick={() => toggleCategoryFilter(seg.category)}
                      >
                        <span className="legend-category">
                          <span className="dot" style={{ background: seg.color }} /> {seg.category}
                        </span>
                        <span className="legend-weight">{gramsToKg(seg.weight)}</span>
                        <span className="legend-percent">{seg.percent.toFixed(1)}%</span>
                      </button>
                    ))}
                  </div>
                  <div className="breakdown-table">
                    <div className="breakdown-row">
                      <span>Total</span>
                      <strong>{gramsToKg(totals.total)}</strong>
                    </div>
                    <div className="breakdown-row">
                      <span>Consumable</span>
                      <strong>{gramsToKg(totals.consumable)}</strong>
                    </div>
                    <div className="breakdown-row">
                      <span>Worn</span>
                      <strong>{gramsToKg(totals.worn)}</strong>
                    </div>
                    <div className="breakdown-row">
                      <span>Base Weight</span>
                      <strong>{gramsToKg(totals.base)}</strong>
                    </div>
                  </div>
                </div>
              </section>

              <div className="work-columns">
                <section
                  className="column column-wide"
                  onDragOver={(e) => e.preventDefault()}
                  onDrop={onPackDrop}
                >
                  <h3>Pack Items by Category</h3>
                  {(activeFilter || selectedWeightType) && (
                    <div className="filter-chip">
                      <span>
                        Filtering:{" "}
                        {activeFilter && <strong>{activeFilter}</strong>}
                        {activeFilter && selectedWeightType && " · "}
                        {selectedWeightType && (
                          <strong>
                            {selectedWeightType.charAt(0).toUpperCase() + selectedWeightType.slice(1)}
                          </strong>
                        )}
                      </span>
                      <button
                        type="button"
                        onClick={() => {
                          setSelectedCategory(null);
                          setSelectedWeightType(null);
                        }}
                      >
                        ✕ Show all
                      </button>
                    </div>
                  )}
                  <div className="pack-list">
                    {activePackRows.length === 0 && <p className="hint">Use + Add to create your first item.</p>}
                    {visibleGroups.map((group) => (
                      <section key={group.category} className="category-group">
                        <div
                          className={`category-group-head ${
                            categoryDragSource && categoryDragSource !== group.category && categoryDragOver === group.category
                              ? "cat-over"
                              : ""
                          }`}
                          onDragOver={(e) => {
                            if (!categoryDragSource) return;
                            e.preventDefault();
                            setCategoryDragOver(group.category);
                          }}
                          onDrop={(e) => onCategoryDrop(e, group.category)}
                        >
                          <div className="cat-head-left">
                            <span
                              className="drag-handle cat-drag"
                              title="Drag to reorder category"
                              draggable
                              onDragStart={(e) => {
                                e.dataTransfer.setData(
                                  "application/json",
                                  JSON.stringify({ type: "category", category: group.category })
                                );
                                setCategoryDragSource(group.category);
                              }}
                              onDragEnd={() => {
                                setCategoryDragSource(null);
                                setCategoryDragOver(null);
                              }}
                            >
                              ::
                            </span>
                            <input
                              defaultValue={group.category}
                              onBlur={(e) => renameGroupCategory(group.category, e.target.value)}
                              className="category-edit"
                            />
                          </div>
                          <span>{gramsToKg(group.totalWeight)}</span>
                        </div>
                        <div className="group-table-head">
                          <span className="cell-drag" />
                          <span className="cell-item-type">Item Type</span>
                          <span className="cell-name">Name</span>
                          <span className="cell-flags">Flags</span>
                          <span className="cell-weight">Weight (g)</span>
                          <span className="cell-qty">Qty</span>
                          <span className="cell-remove" />
                        </div>
                        {group.rows.map((row) => {
                          const index = activePackRows.findIndex((item) => item.id === row.id);
                          return (
                            <div
                              key={row.id}
                              className={`pack-row ${dragOverIndex === index ? "drag-over" : ""} ${
                                Number(row.quantity) === 0 ? "inactive" : ""
                              }`}
                              draggable
                              onDragStart={(e) =>
                                e.dataTransfer.setData(
                                  "application/json",
                                  JSON.stringify({ type: "pack", itemId: row.id })
                                )
                              }
                              onDragEnd={() => setDragOverIndex(null)}
                              onDragOver={(e) => {
                                e.preventDefault();
                                setDragOverIndex(index);
                              }}
                            >
                              <span className="drag-handle cell-drag" title="Drag to reorder">
                                ::
                              </span>
                              <input
                                className="cell-item-type"
                                value={row.gear.itemType}
                                onChange={(e) => updateGear(row.gear.id, { itemType: e.target.value })}
                              />
                              <input
                                className="cell-name"
                                value={row.gear.name}
                                onChange={(e) => updateGear(row.gear.id, { name: e.target.value })}
                              />

                              <div className="flag-buttons cell-flags">
                                <button
                                  type="button"
                                  className={`flag-btn ${row.weightType === "consumable" ? "active" : ""}`}
                                  title="Consumable"
                                  aria-label="Consumable"
                                  onClick={() => toggleWeightFlag(row.id, "consumable")}
                                >
                                  <ConsumableIcon />
                                </button>
                                <button
                                  type="button"
                                  className={`flag-btn ${row.weightType === "worn" ? "active" : ""}`}
                                  title="Worn"
                                  aria-label="Worn"
                                  onClick={() => toggleWeightFlag(row.id, "worn")}
                                >
                                  <WornIcon />
                                </button>
                              </div>

                              <div className="cell-weight field-unit-wrap">
                                <input
                                  type="number"
                                  min="0"
                                  value={Math.max(0, parseNumber(row.weight, 0))}
                                  onChange={(e) =>
                                    setPackItems((prev) =>
                                      prev.map((item) =>
                                        item.id === row.id
                                          ? { ...item, weight: Math.max(0, parseNumber(e.target.value, 0)) }
                                          : item
                                      )
                                    )
                                  }
                                />
                                <span className="field-unit">g</span>
                              </div>

                              <div className="cell-qty field-unit-wrap">
                                <span className="field-unit">×</span>
                                <input
                                  type="number"
                                  min="0"
                                  value={row.quantity}
                                  onChange={(e) =>
                                    setPackItems((prev) =>
                                      prev.map((item) =>
                                        item.id === row.id
                                          ? { ...item, quantity: Math.max(0, parseNumber(e.target.value, 0)) }
                                          : item
                                      )
                                    )
                                  }
                                />
                              </div>

                              <button
                                className="cell-remove row-remove"
                                type="button"
                                title="Remove item"
                                aria-label="Remove item"
                                onClick={() => {
                                  if (!window.confirm(`Remove "${row.gear.name}" from this pack?`)) return;
                                  setPackItems((prev) => prev.filter((item) => item.id !== row.id));
                                }}
                              >
                                <RemoveItemIcon />
                              </button>
                            </div>
                          );
                        })}
                        {(() => {
                          const draft = getDraft(group.category);
                          const suggestions = matchingGears(draft.name);
                          const suggestedGear = gears.find((gear) => gear.id === draft.gearId);
                          return (
                            <div className="category-group-actions">
                              {!addOpen[group.category] ? (
                                <button
                                  type="button"
                                  className="add-item-toggle"
                                  onClick={() => setAddOpen((prev) => ({ ...prev, [group.category]: true }))}
                                >
                                  + Add item
                                </button>
                              ) : (
                                <>
                              <div className="pack-row add-row">
                                <span className="drag-handle muted">+</span>
                                <input
                                  className="cell-item-type"
                                  value={draft.itemType}
                                  onChange={(e) => updateDraft(group.category, { itemType: e.target.value })}
                                />
                                <div className="name-cell">
                                  <input
                                    className="cell-name"
                                    placeholder="Add item…"
                                    value={draft.name}
                                    onChange={(e) =>
                                      updateDraft(group.category, {
                                        name: e.target.value,
                                        gearId: "",
                                        variantId: ""
                                      })
                                    }
                                  />
                                  {suggestions.length > 0 && (
                                    <div className="suggestions">
                                      {suggestions.map((gear) => (
                                        <button
                                          key={gear.id}
                                          type="button"
                                          className="suggestion-btn"
                                          onClick={() => applyGearSuggestion(group.category, gear.id)}
                                        >
                                          {gear.name}
                                        </button>
                                      ))}
                                    </div>
                                  )}
                                </div>
                                <div className="flag-buttons cell-flags">
                                  <button
                                    type="button"
                                    className={`flag-btn ${draft.weightType === "consumable" ? "active" : ""}`}
                                    aria-label="Consumable"
                                    onClick={() =>
                                      updateDraft(group.category, {
                                        weightType:
                                          draft.weightType === "consumable" ? "base" : "consumable"
                                      })
                                    }
                                  >
                                    <ConsumableIcon />
                                  </button>
                                  <button
                                    type="button"
                                    className={`flag-btn ${draft.weightType === "worn" ? "active" : ""}`}
                                    aria-label="Worn"
                                    onClick={() =>
                                      updateDraft(group.category, {
                                        weightType: draft.weightType === "worn" ? "base" : "worn"
                                      })
                                    }
                                  >
                                    <WornIcon />
                                  </button>
                                </div>
                                <div className="cell-weight field-unit-wrap">
                                  <input
                                    type="number"
                                    min="0"
                                    value={Math.max(0, parseNumber(draft.weight, 0))}
                                    onChange={(e) =>
                                      updateDraft(group.category, { weight: Math.max(0, parseNumber(e.target.value, 0)) })
                                    }
                                  />
                                  <span className="field-unit">g</span>
                                </div>
                                <div className="cell-qty field-unit-wrap">
                                  <span className="field-unit">×</span>
                                  <input
                                    type="number"
                                    min="0"
                                    value={Math.max(0, parseNumber(draft.quantity, 1))}
                                    onChange={(e) =>
                                      updateDraft(group.category, {
                                        quantity: Math.max(0, parseNumber(e.target.value, 0))
                                      })
                                    }
                                  />
                                </div>
                                <button className="cell-remove" type="button" onClick={() => addItemFromDraft(group.category)}>
                                  + Add
                                </button>
                              </div>
                              {suggestedGear && suggestedGear.variants.length > 1 && (
                                <div className="variant-hint">
                                  <span>Variant</span>
                                  <select
                                    value={draft.variantId || suggestedGear.variants[0].id}
                                    onChange={(e) => applyDraftVariant(group.category, e.target.value)}
                                  >
                                    {suggestedGear.variants.map((variant) => (
                                      <option key={variant.id} value={variant.id}>
                                        {variant.name} ({variant.weight}g)
                                      </option>
                                    ))}
                                  </select>
                                </div>
                              )}
                              <button
                                type="button"
                                className="add-item-toggle done"
                                onClick={() => setAddOpen((prev) => ({ ...prev, [group.category]: false }))}
                              >
                                Done
                              </button>
                                </>
                              )}
                            </div>
                          );
                        })()}
                      </section>
                    ))}
                    <button type="button" className="add-category-btn" onClick={addCategory}>
                      + Add category
                    </button>
                  </div>
                </section>
              </div>

                  {importModal && (
                    <div className="modal-overlay" onClick={closeImportModal}>
                      <div className="modal-panel" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-head">
                          <h3>
                            {importModal === "url"
                              ? "Import from LighterPack URL"
                              : "Import from CSV file"}
                          </h3>
                          <button type="button" onClick={closeImportModal}>
                            ✕
                          </button>
                        </div>

                        <section className="import-section">
                          <h4>Mapping</h4>
                          <div className="import-options">
                            <label>
                              Name / description
                              <select
                                value={importConfig.mappingMode}
                                onChange={(e) =>
                                  setImportConfig((prev) => ({ ...prev, mappingMode: e.target.value }))
                                }
                              >
                                <option value="name_to_name">Name → Name, Description → Description</option>
                                <option value="description_to_name">Description → Name, Name → Item Type</option>
                              </select>
                            </label>

                            <label className="checkbox-inline">
                              <input
                                type="checkbox"
                                checked={importConfig.autoFillItemTypeFromCategory}
                                onChange={(e) =>
                                  setImportConfig((prev) => ({
                                    ...prev,
                                    autoFillItemTypeFromCategory: e.target.checked
                                  }))
                                }
                              />
                              Autofill item type from category
                            </label>

                            {importConfig.mappingMode === "description_to_name" && (
                              <label>
                                Description field
                                <select
                                  value={importConfig.descriptionSource}
                                  onChange={(e) =>
                                    setImportConfig((prev) => ({ ...prev, descriptionSource: e.target.value }))
                                  }
                                >
                                  <option value="empty">Empty</option>
                                  <option value="variant">Variant (if available)</option>
                                </select>
                              </label>
                            )}
                          </div>
                        </section>

                        {importModal === "url" && (
                          <section className="import-section">
                            <h4>LighterPack URL</h4>
                            <form className="import-url-form" onSubmit={handleImportUrl}>
                              <input
                                placeholder="https://lighterpack.com/r/..."
                                value={importUrl}
                                onChange={(e) => setImportUrl(e.target.value)}
                              />
                              <button type="submit" disabled={importing}>
                                {importing ? "Importing..." : "Import URL"}
                              </button>
                            </form>
                          </section>
                        )}

                        {importModal === "csv" && (
                          <section className="import-section">
                            <h4>CSV file</h4>
                            <div className="csv-row">
                              <label className="file-label">
                                {csvStaged ? "Choose another file" : "Choose CSV file"}
                                <input type="file" accept=".csv,text/csv" onChange={handleCsvFile} />
                              </label>
                              {csvStaged && (
                                <>
                                  <span className="csv-staged">
                                    {csvStaged.fileName} — {csvStaged.entries.length} rows
                                  </span>
                                  <button type="button" onClick={confirmCsvImport}>
                                    Import {csvStaged.entries.length} items
                                  </button>
                                </>
                              )}
                            </div>
                          </section>
                        )}

                        {importStatus && <p className="status">{importStatus}</p>}
                      </div>
                    </div>
                  )}
                </>
              )}
            </>
          )}
        </section>
      </main>
    </div>
  );
}
