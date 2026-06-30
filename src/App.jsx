import React, { useEffect, useMemo, useRef, useState } from "react";
import { id, parseNumber, normalizeWeightType, normalizeText, gramsToKg, reorder, mutatePackItemsForPack, applyOrder } from "./lib/util.js";
import { normalizeCategories, primaryCategory, mergeOrCreateGear, nextPurchase } from "./lib/gear.js";
import { parseLighterpackCsv, parseLighterpackHtml, mapImportedEntry, packToCsv } from "./lib/import.js";
import { buildPieSegments, describeDonutArc } from "./lib/chart.js";
import { STORAGE_KEY, readStorage, normalizeData, defaultData } from "./lib/storage.js";
import { useGoogleSync } from "./hooks/useGoogleSync.js";
import Landing from "./components/Landing.jsx";
import logoUrl from "./logo.png";

// Currency symbol shown before the number.
const CURRENCY = "$";

function formatPrice(value) {
  const v = Math.max(0, parseNumber(value, 0));
  return `${CURRENCY}${v.toLocaleString("en-US", { maximumFractionDigits: 2 })}`;
}

function syncLabel(status) {
  if (status === "syncing") return "Saving…";
  if (status === "saved") return "Synced";
  if (status === "permission") return "Drive access needed";
  if (status === "error") return "Sync error";
  return "";
}

// Empty string (epoch 0) when nothing was ever saved, so default/unedited local
// data never wins last-write-wins against real cloud data on first sign-in.
// A real timestamp is only set once the user actually edits something.
function readInitialUpdatedAt() {
  try {
    return JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}").updatedAt || "";
  } catch {
    return "";
  }
}

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

function PanelIcon() {
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
      <rect width="18" height="18" x="3" y="3" rx="2" />
      <path d="M9 3v18" />
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

function StarIcon({ filled }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill={filled ? "currentColor" : "none"}
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M12 2l3.09 6.26L22 9.27l-5 4.87 1.18 6.88L12 17.77l-6.18 3.25L7 14.14 2 9.27l6.91-1.01L12 2z" />
    </svg>
  );
}

function CartIcon() {
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
      <circle cx="8" cy="21" r="1" />
      <circle cx="19" cy="21" r="1" />
      <path d="M2.05 2.05h2l2.66 12.42a2 2 0 0 0 2 1.58h9.78a2 2 0 0 0 1.95-1.57l1.65-7.43H5.12" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="15"
      height="15"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.4"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M20 6 9 17l-5-5" />
    </svg>
  );
}

// Favorite star + purchase-status (none/need/owned) controls. Library rows use
// the default (always-visible) style; pack rows pass `flag` to render them like
// the consumable/worn flags (hover-revealed until set).
function MarkControls({ favorite, purchase, onToggleFavorite, onCyclePurchase, flag }) {
  const status = purchase || "";
  const base = flag ? "flag-btn" : "mark-btn";
  const favBtn = (
    <button
      type="button"
      className={`${base} mark-fav ${favorite ? "active" : ""}`}
      title={favorite ? "Unfavorite" : "Favorite"}
      aria-label="Toggle favorite"
      aria-pressed={favorite}
      onClick={onToggleFavorite}
    >
      <StarIcon filled={favorite} />
    </button>
  );
  const buyBtn = (
    <button
      type="button"
      className={`${base} mark-buy mark-${status || "none"} ${status ? "active" : ""}`}
      title={status === "need" ? "Need to buy" : status === "owned" ? "Owned" : "Set purchase status"}
      aria-label="Cycle purchase status"
      onClick={onCyclePurchase}
    >
      {status === "owned" ? <CheckIcon /> : <CartIcon />}
    </button>
  );
  if (flag) {
    return (
      <>
        {favBtn}
        {buyBtn}
      </>
    );
  }
  return (
    <span className="mark-controls">
      {favBtn}
      {buyBtn}
    </span>
  );
}

export default function App() {
  const initial = readStorage();

  const [gears, setGears] = useState(initial.gears);
  const [packs, setPacks] = useState(initial.packs);
  const [packItems, setPackItems] = useState(initial.packItems);
  const [activePackId, setActivePackId] = useState(initial.packs[0]?.id || "");
  const [dragOverIndex, setDragOverIndex] = useState(null);
  const [updatedAt, setUpdatedAt] = useState(readInitialUpdatedAt);
  const [entered, setEntered] = useState(
    () =>
      localStorage.getItem("ulpacker.entered") === "1" ||
      localStorage.getItem("ulpacker.googleSignedIn") === "1"
  );
  const updatedAtRef = useRef(updatedAt);
  const lastSavedRef = useRef(JSON.stringify({ gears: initial.gears, packs: initial.packs, packItems: initial.packItems }));
  const appliedUpdatedAt = useRef(null);

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
  const [selectedMark, setSelectedMark] = useState(null);
  const [categoryDrafts, setCategoryDrafts] = useState({});
  const [libraryQuery, setLibraryQuery] = useState("");
  const [libraryMark, setLibraryMark] = useState(null);
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
  const [sidebarOpen, setSidebarOpen] = useState(() => {
    try {
      return JSON.parse(localStorage.getItem("ulpacker.settings") || "{}").sidebarOpen !== false;
    } catch {
      return true;
    }
  });
  const [showPrice, setShowPrice] = useState(() => {
    try {
      return Boolean(JSON.parse(localStorage.getItem("ulpacker.settings") || "{}").showPrice);
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
    setSelectedMark(null);
    setNewCategories([]);
  }, [activePackId]);

  useEffect(() => {
    const serialized = JSON.stringify({ gears, packs, packItems });
    let ts = updatedAtRef.current;
    if (serialized !== lastSavedRef.current) {
      // Real change: bump the timestamp (or keep a just-applied cloud one).
      lastSavedRef.current = serialized;
      ts = appliedUpdatedAt.current || new Date().toISOString();
      appliedUpdatedAt.current = null;
      updatedAtRef.current = ts;
      setUpdatedAt(ts);
    }
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ gears, packs, packItems, updatedAt: ts }));
  }, [gears, packs, packItems]);

  function applyCloud(cloud) {
    const norm = normalizeData(cloud) || defaultData();
    appliedUpdatedAt.current = cloud?.updatedAt || new Date().toISOString();
    setGears(norm.gears);
    setPacks(norm.packs);
    setPackItems(norm.packItems);
    setActivePackId((prev) => (norm.packs.some((pack) => pack.id === prev) ? prev : norm.packs[0]?.id || ""));
  }

  const sync = useGoogleSync({
    buildData: () => ({ gears, packs, packItems, updatedAt }),
    applyCloud,
    updatedAt
  });

  useEffect(() => {
    localStorage.setItem("ulpacker.settings", JSON.stringify({ hideZeroQty, sidebarOpen, showPrice }));
  }, [hideZeroQty, sidebarOpen, showPrice]);

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
        const qty = Math.max(0, Number(item.quantity || 0));
        const priceVariant = gear.variants.find((v) => v.id === item.variantId) || gear.variants[0];
        const unitPrice = Math.max(0, parseNumber(priceVariant?.price, 0));
        return {
          ...item,
          gear,
          category: item.category || primaryCategory(gear),
          priceVariantId: priceVariant?.id || "",
          unitPrice,
          linePrice: qty * unitPrice,
          lineWeight: qty * Math.max(0, parseNumber(item.weight, 0))
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
  totals.price = carriedRows.reduce((sum, row) => sum + row.linePrice, 0);

  const categoryRows = useMemo(() => {
    const grouped = new Map();
    for (const row of carriedRows) {
      const key = row.category || primaryCategory(row.gear);
      const entry = grouped.get(key) || { weight: 0, price: 0 };
      entry.weight += row.lineWeight;
      entry.price += row.linePrice;
      grouped.set(key, entry);
    }
    return [...grouped.entries()]
      .map(([category, v]) => ({ category, weight: v.weight, price: v.price }))
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
      if (selectedMark === "favorite" && !row.gear.favorite) continue;
      if (selectedMark === "need" && row.gear.purchase !== "need") continue;
      const category = row.category || primaryCategory(row.gear);
      if (!grouped.has(category)) {
        grouped.set(category, { category, rows: [], totalWeight: 0, totalPrice: 0, gearIds: new Set() });
      }
      const group = grouped.get(category);
      group.rows.push(row);
      group.totalWeight += row.lineWeight;
      group.totalPrice += row.linePrice;
      group.gearIds.add(row.gear.id);
    }
    // Manual category order (per pack); new categories fall to the end.
    const ordered = applyOrder([...grouped.keys()], activePack?.categoryOrder || []);
    // Empty categories the user just created (no items yet).
    for (const name of newCategories) {
      if (!grouped.has(name)) {
        grouped.set(name, { category: name, rows: [], totalWeight: 0, totalPrice: 0, gearIds: new Set() });
        ordered.push(name);
      }
    }
    if (ordered.length === 0) {
      return [{ category: "Uncategorized", rows: [], totalWeight: 0, totalPrice: 0, gearIds: new Set() }];
    }
    return ordered.map((c) => grouped.get(c));
  }, [activePackRows, activePack, hideZeroQty, selectedWeightType, selectedMark, newCategories]);

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

  function togglePackMark(mark) {
    setSelectedMark((prev) => (prev === mark ? null : mark));
  }

  function toggleLibraryMark(mark) {
    setLibraryMark((prev) => (prev === mark ? null : mark));
  }
  const filteredGears = useMemo(() => {
    const q = normalizeText(libraryQuery);
    return gears.filter((gear) => {
      if (libraryMark === "favorite" && !gear.favorite) return false;
      if (libraryMark === "need" && gear.purchase !== "need") return false;
      if (!q) return true;
      const categories = (gear.categories || []).join(" ");
      return normalizeText(`${gear.name} ${gear.itemType} ${gear.description} ${categories}`).includes(q);
    });
  }, [gears, libraryQuery, libraryMark]);

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

  function deletePack(target) {
    if (!target) return;
    if (!window.confirm(`Delete pack "${target.name}"? Its items will be removed.`)) return;
    const targetId = target.id;
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
    // Only move the selection if we deleted the pack that's currently open.
    if (activePackId === targetId) setActivePackId(remaining[0].id);
  }

  function deleteActivePack() {
    deletePack(activePack);
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
                { id: id(), name: `Variant ${gear.variants.length + 1}`, weight: 0, price: 0 }
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

  function exportPackCsv() {
    if (!activePack) return;
    const csv = packToCsv(
      activePackRows.map((row) => ({
        itemType: row.gear.itemType,
        name: row.gear.name,
        category: row.category,
        quantity: row.quantity,
        weight: row.weight,
        weightType: row.weightType
      }))
    );
    const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    const safeName = (activePack.name || "pack").trim().replace(/[^\w.-]+/g, "_") || "pack";
    link.href = url;
    link.download = `${safeName}.csv`;
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

  function enterApp() {
    localStorage.setItem("ulpacker.entered", "1");
    setEntered(true);
  }

  if (!entered) {
    return (
      <Landing
        configured={sync.configured}
        onSignIn={() => {
          enterApp();
          sync.signIn();
        }}
        onContinue={enterApp}
      />
    );
  }

  return (
    <div className="app">
      <header className="topbar">
        <div className="topbar-top">
          <img className="brand-logo" src={logoUrl} alt="ULPacker" />
          <div className="data-tools">
            <div className="menu">
              <button type="button" className="menu-trigger">
                <ExportIcon />
                Export
              </button>
              <div className="menu-list">
                <button type="button" onClick={exportPackCsv}>
                  Export pack to CSV
                </button>
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
                <label className="menu-check">
                  <input
                    type="checkbox"
                    checked={showPrice}
                    onChange={(e) => setShowPrice(e.target.checked)}
                  />
                  Show prices
                </label>
              </div>
            </div>
            {sync.account ? (
              <div className="menu account-menu">
                <button type="button" className="menu-trigger account-trigger">
                  {sync.account.picture ? (
                    <img
                      className="account-avatar"
                      src={sync.account.picture}
                      alt=""
                      referrerPolicy="no-referrer"
                    />
                  ) : (
                    <span className="account-avatar account-avatar-fallback">
                      {(sync.account.name || "?").charAt(0).toUpperCase()}
                    </span>
                  )}
                  <span className={`sync-dot sync-${sync.status}`} title={syncLabel(sync.status)} />
                </button>
                <div className="menu-list account-list">
                  <div className="account-info">
                    <strong>{sync.account.name}</strong>
                    <small>{sync.account.email}</small>
                    <small className={`sync-line sync-line-${sync.status}`}>{syncLabel(sync.status)}</small>
                  </div>
                  {(sync.status === "permission" || sync.status === "error") && (
                    <button type="button" onClick={sync.signIn}>
                      Reconnect Drive
                    </button>
                  )}
                  <button type="button" onClick={sync.signOut}>
                    Sign out
                  </button>
                </div>
              </div>
            ) : sync.configured ? (
              <button type="button" className="menu-trigger signin-trigger" onClick={sync.signIn}>
                Sign in
              </button>
            ) : null}
          </div>
        </div>
        <div className="nav-row">
          {view === "packs" && (
            <button
              type="button"
              className={`sidebar-toggle ${sidebarOpen ? "active" : ""}`}
              onClick={() => setSidebarOpen((open) => !open)}
              title={sidebarOpen ? "Hide packs sidebar" : "Show packs sidebar"}
              aria-label="Toggle packs sidebar"
              aria-pressed={sidebarOpen}
            >
              <PanelIcon />
            </button>
          )}
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
        </div>
      </header>

      <main
        className={`dashboard ${
          view === "library" || (view === "packs" && !sidebarOpen) ? "library-layout" : ""
        }`}
      >
        {view === "packs" && sidebarOpen && (
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
                <div className="pack-card-wrap" key={pack.id}>
                  <button
                    type="button"
                    className={`pack-card ${activePack?.id === pack.id ? "active" : ""}`}
                    onClick={() => setActivePackId(pack.id)}
                  >
                    <strong>{pack.name}</strong>
                    <small>{pack.description || "No description"}</small>
                    <span>{gramsToKg(packWeight)}</span>
                  </button>
                  <button
                    type="button"
                    className="pack-card-delete"
                    title="Delete pack"
                    aria-label={`Delete pack ${pack.name}`}
                    onClick={(e) => {
                      e.stopPropagation();
                      deletePack(pack);
                    }}
                  >
                    <TrashIcon />
                  </button>
                </div>
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
                  <div className="mark-filters">
                    <button
                      type="button"
                      className={`mark-filter ${libraryMark === "favorite" ? "active mark-fav" : ""}`}
                      onClick={() => toggleLibraryMark("favorite")}
                    >
                      <StarIcon filled={libraryMark === "favorite"} /> Favorites
                    </button>
                    <button
                      type="button"
                      className={`mark-filter ${libraryMark === "need" ? "active mark-need" : ""}`}
                      onClick={() => toggleLibraryMark("need")}
                    >
                      <CartIcon /> To buy
                    </button>
                  </div>
                </div>
                <div className="library-table-head">
                  <span />
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
                      <div className="gear-marks">
                        <MarkControls
                          favorite={gear.favorite}
                          purchase={gear.purchase}
                          onToggleFavorite={() => updateGear(gear.id, { favorite: !gear.favorite })}
                          onCyclePurchase={() => updateGear(gear.id, { purchase: nextPurchase(gear.purchase) })}
                        />
                      </div>
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
                              <input
                                type="number"
                                min="0"
                                className="variant-price"
                                value={Math.max(0, parseNumber(variant.price, 0))}
                                onChange={(e) =>
                                  updateVariant(gear.id, variant.id, {
                                    price: Math.max(0, parseNumber(e.target.value, 0))
                                  })
                                }
                              />
                              <span>{CURRENCY}</span>
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

              <section className={`analytics ${showPrice ? "show-price" : ""}`}>
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
                <div className={`legend ${showPrice ? "show-price" : ""}`}>
                  <h3>Category breakdown</h3>
                  {pieSegments.length === 0 && <p className="hint">No carried items yet.</p>}
                  <div className="legend-table">
                    <div className="legend-table-head">
                      <span>Category</span>
                      {showPrice && <span className="legend-price">Price</span>}
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
                        {showPrice && <span className="legend-price">{formatPrice(seg.price)}</span>}
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
                    {showPrice && (
                      <div className="breakdown-row">
                        <span>Total price</span>
                        <strong>{formatPrice(totals.price)}</strong>
                      </div>
                    )}
                  </div>
                </div>
              </section>

              <div className="work-columns">
                <section
                  className="column column-wide"
                  onDragOver={(e) => e.preventDefault()}
                  onDrop={onPackDrop}
                >
                  <div className="pack-list-head">
                    <h3>Pack Items by Category</h3>
                    <div className="mark-filters">
                      <button
                        type="button"
                        className={`mark-filter ${selectedMark === "favorite" ? "active mark-fav" : ""}`}
                        onClick={() => togglePackMark("favorite")}
                      >
                        <StarIcon filled={selectedMark === "favorite"} /> Favorites
                      </button>
                      <button
                        type="button"
                        className={`mark-filter ${selectedMark === "need" ? "active mark-need" : ""}`}
                        onClick={() => togglePackMark("need")}
                      >
                        <CartIcon /> To buy
                      </button>
                    </div>
                  </div>
                  {(activeFilter || selectedWeightType || selectedMark) && (
                    <div className="filter-chip">
                      <span>
                        Filtering:{" "}
                        {activeFilter && <strong>{activeFilter}</strong>}
                        {activeFilter && (selectedWeightType || selectedMark) && " · "}
                        {selectedWeightType && (
                          <strong>
                            {selectedWeightType.charAt(0).toUpperCase() + selectedWeightType.slice(1)}
                          </strong>
                        )}
                        {selectedWeightType && selectedMark && " · "}
                        {selectedMark && (
                          <strong>{selectedMark === "favorite" ? "Favorites" : "To buy"}</strong>
                        )}
                      </span>
                      <button
                        type="button"
                        onClick={() => {
                          setSelectedCategory(null);
                          setSelectedWeightType(null);
                          setSelectedMark(null);
                        }}
                      >
                        ✕ Show all
                      </button>
                    </div>
                  )}
                  <div className={`pack-list ${showPrice ? "show-price" : ""}`}>
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
                        </div>
                        <div className="group-table-head">
                          <span className="cell-drag" />
                          <span className="cell-item-type">Item Type</span>
                          <span className="cell-name">Name</span>
                          <span className="cell-flags">Flags</span>
                          {showPrice && <span className="cell-price">Price</span>}
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
                                <MarkControls
                                  flag
                                  favorite={row.gear.favorite}
                                  purchase={row.gear.purchase}
                                  onToggleFavorite={() =>
                                    updateGear(row.gear.id, { favorite: !row.gear.favorite })
                                  }
                                  onCyclePurchase={() =>
                                    updateGear(row.gear.id, { purchase: nextPurchase(row.gear.purchase) })
                                  }
                                />
                              </div>

                              {showPrice && (
                                <div className="cell-price field-unit-wrap">
                                  <input
                                    type="number"
                                    min="0"
                                    value={row.unitPrice}
                                    onChange={(e) =>
                                      row.priceVariantId &&
                                      updateVariant(row.gear.id, row.priceVariantId, {
                                        price: Math.max(0, parseNumber(e.target.value, 0))
                                      })
                                    }
                                  />
                                  <span className="field-unit">{CURRENCY}</span>
                                </div>
                              )}

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
                              {addOpen[group.category] && (
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
                                </>
                              )}
                              <div className="category-total-row">
                                <span className="cell-drag" />
                                <span className="cell-item-type" />
                                <span className="cell-name">
                                  <button
                                    type="button"
                                    className={`add-item-toggle ${addOpen[group.category] ? "done" : ""}`}
                                    onClick={() =>
                                      setAddOpen((prev) => ({ ...prev, [group.category]: !prev[group.category] }))
                                    }
                                  >
                                    {addOpen[group.category] ? "Done" : "+ Add item"}
                                  </button>
                                </span>
                                <span className="cell-flags" />
                                {showPrice && (
                                  <span className="cell-price cat-total">{formatPrice(group.totalPrice)}</span>
                                )}
                                <span className="cell-weight cat-total">{gramsToKg(group.totalWeight)}</span>
                                <span className="cell-qty" />
                                <span className="cell-remove" />
                              </div>
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
