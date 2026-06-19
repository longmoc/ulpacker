import React, { useEffect, useMemo, useState } from "react";
import { id, parseNumber, normalizeWeightType, normalizeText, gramsToKg, reorder, mutatePackItemsForPack } from "./lib/util.js";
import { normalizeCategories, primaryCategory, mergeOrCreateGear } from "./lib/gear.js";
import { parseLighterpackCsv, parseLighterpackHtml, mapImportedEntry } from "./lib/import.js";
import { buildPieSegments, describeDonutArc } from "./lib/chart.js";
import { STORAGE_KEY, readStorage } from "./lib/storage.js";

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
    <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true">
      <path
        d="M9 3h6l1 3v4a4 4 0 0 1 4 4v3h-2v4H6v-4H4v-3a4 4 0 0 1 4-4V6l1-3Zm2 3v4h2V6h-2Zm-3 6a2 2 0 0 0-2 2v1h12v-1a2 2 0 0 0-2-2H8Z"
        fill="currentColor"
      />
    </svg>
  );
}

function WornIcon() {
  return (
    <svg viewBox="0 0 24 24" width="15" height="15" aria-hidden="true">
      <path
        d="M9 3h6l1 2 3 1v4h-2v11H7V10H5V6l3-1 1-2Zm1.2 2-.6 1.2-1.6.5v1.3h8V6.7l-1.6-.5L13.8 5h-3.6Z"
        fill="currentColor"
      />
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
  const [importModalOpen, setImportModalOpen] = useState(false);
  const [view, setView] = useState("packs");
  const [chartHover, setChartHover] = useState(null);
  const [categoryDrafts, setCategoryDrafts] = useState({});
  const [libraryQuery, setLibraryQuery] = useState("");
  const [expandedGears, setExpandedGears] = useState({});
  const [libraryPackTarget, setLibraryPackTarget] = useState({});
  const [importConfig, setImportConfig] = useState({
    mappingMode: "name_to_name",
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
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ gears, packs, packItems }));
  }, [gears, packs, packItems]);

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
    list: activePackRows.reduce((sum, row) => sum + row.lineWeight, 0),
    carried: carriedRows.reduce((sum, row) => sum + row.lineWeight, 0),
    base: carriedRows.filter((row) => row.weightType === "base").reduce((sum, row) => sum + row.lineWeight, 0),
    worn: carriedRows.filter((row) => row.weightType === "worn").reduce((sum, row) => sum + row.lineWeight, 0),
    consumable: carriedRows
      .filter((row) => row.weightType === "consumable")
      .reduce((sum, row) => sum + row.lineWeight, 0)
  };

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
      const category = row.category || primaryCategory(row.gear);
      if (!grouped.has(category)) {
        grouped.set(category, { category, rows: [], totalWeight: 0, gearIds: new Set() });
      }
      const group = grouped.get(category);
      group.rows.push(row);
      group.totalWeight += row.lineWeight;
      group.gearIds.add(row.gear.id);
    }
    const sorted = [...grouped.values()].sort((a, b) => b.totalWeight - a.totalWeight);
    if (sorted.length === 0) {
      return [{ category: "Uncategorized", rows: [], totalWeight: 0, gearIds: new Set() }];
    }
    return sorted;
  }, [activePackRows]);
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
      createdAt: new Date().toISOString()
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
    if (!activePack || packs.length <= 1) return;
    const targetId = activePack.id;
    const nextPacks = packs.filter((pack) => pack.id !== targetId);
    setPacks(nextPacks);
    setPackItems((prev) => prev.filter((item) => item.packId !== targetId));
    setActivePackId(nextPacks[0]?.id || "");
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
      setImportStatus("Hãy tạo pack trước khi import.");
      return;
    }

    if (!entries.length) {
      setImportStatus("Không tìm thấy dữ liệu để import.");
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
    setImportModalOpen(false);
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

  async function handleImportCsv(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    try {
      const text = await file.text();
      const entries = parseLighterpackCsv(text);
      importEntries(entries, `CSV: ${file.name}`);
    } catch {
      setImportStatus("Cannot read CSV.");
    } finally {
      e.target.value = "";
    }
  }

  return (
    <div className="app">
      <header className="topbar">
        <h1>ULPacker</h1>
        <p>Pack dashboard with reusable gear library, drag-and-drop, and pie-chart analytics.</p>
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
                <h3>Add New Gear</h3>
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
                        value={gear.name}
                        onChange={(e) => updateGear(gear.id, { name: e.target.value })}
                      />
                      <input
                        value={gear.itemType}
                        onChange={(e) => updateGear(gear.id, { itemType: e.target.value })}
                      />
                      <input
                        value={gear.description}
                        onChange={(e) => updateGear(gear.id, { description: e.target.value })}
                      />
                      <CategoryChipsInput
                        categories={gear.categories}
                        onChange={(next) => updateGear(gear.id, { categories: next })}
                        placeholder="Add category"
                      />
                      <button type="button" className="variant-toggle" onClick={() => toggleGearExpanded(gear.id)}>
                        {gear.variants.length} variants
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
                          onClick={() =>
                            addToSpecificPack(
                              gear.id,
                              libraryPackTarget[gear.id] || activePackId || packs[0]?.id || ""
                            )
                          }
                        >
                          Add to Pack
                        </button>
                        <button type="button" className="danger" onClick={() => removeGearFromLibrary(gear.id)}>
                          Delete
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
                <button type="button" onClick={() => setImportModalOpen(true)}>
                  Import Pack
                </button>
                <button type="button" onClick={() => setView("library")}>
                  Gear Library
                </button>
                <button type="button" disabled={packs.length <= 1} onClick={deleteActivePack}>
                  Delete Pack
                </button>
              </div>

              <div className="summary-grid">
                <div className="summary-card">
                  <small>Total Carried</small>
                  <strong>{gramsToKg(totals.carried)}</strong>
                </div>
                <div className="summary-card">
                  <small>Base</small>
                  <strong>{gramsToKg(totals.base)}</strong>
                </div>
                <div className="summary-card">
                  <small>Consumable</small>
                  <strong>{gramsToKg(totals.consumable)}</strong>
                </div>
                <div className="summary-card">
                  <small>Worn</small>
                  <strong>{gramsToKg(totals.worn)}</strong>
                </div>
                <div className="summary-card">
                  <small>Total In List</small>
                  <strong>{gramsToKg(totals.list)}</strong>
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
                          d={describeDonutArc(110, 110, 105, 52, startDeg, endDeg)}
                          fill={seg.color}
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
                      <div key={seg.category} className="legend-row">
                        <span className="legend-category">
                          <span className="dot" style={{ background: seg.color }} /> {seg.category}
                        </span>
                        <span className="legend-weight">{gramsToKg(seg.weight)}</span>
                        <span className="legend-percent">{seg.percent.toFixed(1)}%</span>
                      </div>
                    ))}
                  </div>
                  <div className="breakdown-table">
                    <div className="breakdown-row">
                      <span>Total</span>
                      <strong>{gramsToKg(totals.carried)}</strong>
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
                  <div className="pack-list">
                    {activePackRows.length === 0 && <p className="hint">Use + Add to create your first item.</p>}
                    {packGroups.map((group) => (
                      <section key={group.category} className="category-group">
                        <div className="category-group-head">
                          <input
                            defaultValue={group.category}
                            onBlur={(e) => renameGroupCategory(group.category, e.target.value)}
                            className="category-edit"
                          />
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

                              <input
                                className="cell-weight"
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

                              <input
                                className="cell-qty"
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

                              <button
                                className="cell-remove"
                                type="button"
                                onClick={() =>
                                  setPackItems((prev) => prev.filter((item) => item.id !== row.id))
                                }
                              >
                                Remove
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
                              <div className="group-table-head add-head">
                                <span className="cell-drag" />
                                <span className="cell-item-type" />
                                <span className="cell-name" />
                                <span className="cell-flags" />
                                <span className="cell-weight" />
                                <span className="cell-qty" />
                                <span className="cell-remove" />
                              </div>
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
                                <input
                                  className="cell-weight"
                                  type="number"
                                  min="0"
                                  value={Math.max(0, parseNumber(draft.weight, 0))}
                                  onChange={(e) =>
                                    updateDraft(group.category, { weight: Math.max(0, parseNumber(e.target.value, 0)) })
                                  }
                                />
                                <input
                                  className="cell-qty"
                                  type="number"
                                  min="0"
                                  value={Math.max(0, parseNumber(draft.quantity, 1))}
                                  onChange={(e) =>
                                    updateDraft(group.category, {
                                      quantity: Math.max(0, parseNumber(e.target.value, 0))
                                    })
                                  }
                                />
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
                            </div>
                          );
                        })()}
                      </section>
                    ))}
                  </div>
                </section>
              </div>

                  {importModalOpen && (
                    <div className="modal-overlay" onClick={() => setImportModalOpen(false)}>
                      <div className="modal-panel" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-head">
                          <h3>Import Pack</h3>
                          <button type="button" onClick={() => setImportModalOpen(false)}>
                            ✕
                          </button>
                        </div>

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

                        <div className="import-options">
                          <label>
                            Mapping
                            <select
                              value={importConfig.mappingMode}
                              onChange={(e) =>
                                setImportConfig((prev) => ({ ...prev, mappingMode: e.target.value }))
                              }
                            >
                              <option value="name_to_name">Name -&gt; Name, Description -&gt; Description</option>
                              <option value="description_to_name">
                                Description -&gt; Name, Name -&gt; Item Type
                              </option>
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

                          <label className="file-label">
                            Import CSV
                            <input type="file" accept=".csv,text/csv" onChange={handleImportCsv} />
                          </label>
                        </div>

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
