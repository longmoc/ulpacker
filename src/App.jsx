import React, { useEffect, useMemo, useRef, useState } from "react";
import Cropper from "react-easy-crop";
import { id, parseNumber, normalizeWeightType, normalizeText, gramsToKg, reorder, mutatePackItemsForPack, applyOrder } from "./lib/util.js";
import { normalizeCategories, primaryCategory, mergeOrCreateGear, nextPurchase } from "./lib/gear.js";
import { parseLighterpackCsv, parseLighterpackHtml, mapImportedEntry, packToCsv } from "./lib/import.js";
import { buildPieSegments, describeDonutArc } from "./lib/chart.js";
import {
  STORAGE_KEY,
  TRACKS_KEY,
  SCHEMA_VERSION,
  readLocalBundle,
  buildPortableBundle,
  applyPortableBundle,
  gcTracks,
  defaultData
} from "./lib/storage.js";
import {
  buildTrackStats,
  buildCumulatives,
  parseGpx,
  snapToTrack,
  anchorAtRouteM,
  joinContiguousSegments,
  MAX_TRIPS,
  MAX_SEGMENTS,
  MAX_TRACK_STORAGE_BYTES,
  MAX_GPX_BYTES
} from "./lib/trail.js";
import { useGoogleSync } from "./hooks/useGoogleSync.js";
import Landing from "./components/Landing.jsx";
import TripsSidebar from "./features/trips/TripsSidebar.jsx";
import TripWorkspace from "./features/trips/TripWorkspace.jsx";
import GpxImportModal from "./features/trips/GpxImportModal.jsx";
import logoUrl from "./logo.png";

// Currency symbol shown before the number.
const CURRENCY = "$";

// Cap the number of packs. Cover images are embedded (base64) in the single
// synced JSON, so this keeps total storage within the ~5MB localStorage budget.
const MAX_PACKS = 20;

// A fresh "Add New Gear" draft (one default variant with weight/price fields).
function blankNewGear() {
  return {
    name: "",
    categories: ["Uncategorized"],
    itemType: "",
    description: "",
    variants: [{ id: id(), name: "Default", weight: "", price: "" }]
  };
}

function formatPrice(value) {
  const v = Math.max(0, parseNumber(value, 0));
  return `${CURRENCY}${v.toLocaleString("en-US", { maximumFractionDigits: 2 })}`;
}

// Pack cover images are a fixed 3:1 landscape. We crop the user's selection to
// that ratio and downscale/compress to keep the embedded data URL small (it is
// stored on the pack and synced inside the single JSON document).
const COVER_ASPECT = 3;
const COVER_OUT_WIDTH = 1200;
const COVER_OUT_HEIGHT = COVER_OUT_WIDTH / COVER_ASPECT; // 400

function getCroppedImg(src, pixelCrop) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => {
      try {
        const canvas = document.createElement("canvas");
        canvas.width = COVER_OUT_WIDTH;
        canvas.height = COVER_OUT_HEIGHT;
        const ctx = canvas.getContext("2d");
        ctx.drawImage(
          image,
          pixelCrop.x,
          pixelCrop.y,
          pixelCrop.width,
          pixelCrop.height,
          0,
          0,
          COVER_OUT_WIDTH,
          COVER_OUT_HEIGHT
        );
        resolve(canvas.toDataURL("image/jpeg", 0.82));
      } catch (err) {
        reject(err);
      }
    };
    image.onerror = reject;
    image.src = src;
  });
}

function syncLabel(status) {
  if (status === "syncing") return "Saving…";
  if (status === "saved") return "Synced";
  if (status === "permission") return "Drive access needed";
  if (status === "error") return "Sync error";
  return "";
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

function TotalIcon() {
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
      <path d="M12 2 2 7l10 5 10-5-10-5Z" />
      <path d="m2 17 10 5 10-5" />
      <path d="m2 12 10 5 10-5" />
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

function ImageIcon() {
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
      <rect x="3" y="3" width="18" height="18" rx="2" />
      <circle cx="9" cy="9" r="2" />
      <path d="m21 15-4.5-4.5L5 22" />
    </svg>
  );
}

function PencilIcon() {
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
      <path d="M12 20h9" />
      <path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
    </svg>
  );
}

function ArrowUpIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="20"
      height="20"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M12 19V5" />
      <path d="m5 12 7-7 7 7" />
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

function UserIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="18"
      height="18"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <circle cx="12" cy="8" r="4" />
      <path d="M4 21v-1a6 6 0 0 1 6-6h4a6 6 0 0 1 6 6v1" />
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

function PlusIcon() {
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
      <path d="M12 5v14" />
      <path d="M5 12h14" />
    </svg>
  );
}

function XIcon() {
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
      <path d="M18 6 6 18" />
      <path d="m6 6 12 12" />
    </svg>
  );
}

function SearchIcon() {
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
      <circle cx="11" cy="11" r="7" />
      <path d="m21 21-4.3-4.3" />
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

// Floating preview shown while hovering a sidebar pack card: the cover image at
// full vividness with the name over it, then description + the five weights.
// Positioned below the cursor (flips above near the screen bottom) so it stays
// clear of the card's top-right delete icon. pointer-events: none so it never
// steals hover from the card underneath.
function PackHoverPreview({ pack, pos, weights }) {
  const PW = 280;
  const PH = 250;
  const GAP = 18;
  let left = pos.x - PW / 2;
  left = Math.max(8, Math.min(left, window.innerWidth - PW - 8));
  const below = pos.y + GAP;
  const top = below + PH > window.innerHeight ? Math.max(8, pos.y - GAP - PH) : below;
  const kg = (g) => `${(g / 1000).toFixed(2)} kg`;
  return (
    <div className="pack-hover" style={{ left, top, width: PW }}>
      {pack.image ? (
        <div className="pack-hover-img">
          <img src={pack.image} alt="" />
          <strong>{pack.name}</strong>
        </div>
      ) : (
        <strong className="pack-hover-title">{pack.name}</strong>
      )}
      <div className="pack-hover-body">
        {pack.description && <p className="pack-hover-desc">{pack.description}</p>}
        <div className="pack-hover-weights">
          <span><BackpackIcon /> Carried</span>
          <b>{kg(weights.carried)}</b>
          <span><BoxIcon /> Base</span>
          <b>{kg(weights.base)}</b>
          <span><ConsumableIcon /> Consumable</span>
          <b>{kg(weights.consumable)}</b>
          <span><WornIcon /> Worn</span>
          <b>{kg(weights.worn)}</b>
          <span><TotalIcon /> Total</span>
          <b>{kg(weights.total)}</b>
        </div>
      </div>
    </div>
  );
}

export default function App() {
  const initial = readLocalBundle();

  const [gears, setGears] = useState(initial.doc.gears);
  const [packs, setPacks] = useState(initial.doc.packs);
  const [packItems, setPackItems] = useState(initial.doc.packItems);
  const [trips, setTrips] = useState(initial.doc.trips);
  const [tracks, setTracks] = useState(initial.tracks);
  const [activePackId, setActivePackId] = useState(initial.doc.packs[0]?.id || "");
  const [activeTripId, setActiveTripId] = useState(initial.doc.trips[0]?.id || "");
  const [gpxImport, setGpxImport] = useState(null); // staged GPX preview modal
  const [dragOverIndex, setDragOverIndex] = useState(null);
  const [updatedAt, setUpdatedAt] = useState(initial.doc.updatedAt || "");
  const [entered, setEntered] = useState(
    () =>
      localStorage.getItem("ulpacker.entered") === "1" ||
      localStorage.getItem("ulpacker.googleSignedIn") === "1"
  );
  const updatedAtRef = useRef(updatedAt);
  const lastSavedRef = useRef(
    JSON.stringify({ gears: initial.doc.gears, packs: initial.doc.packs, packItems: initial.doc.packItems, trips: initial.doc.trips })
  );
  const appliedUpdatedAt = useRef(null);
  // Set true right after we apply cloud/import data so the doc-save effect does
  // NOT immediately re-persist the tracks map (already written by the apply).
  const skipTrackWrite = useRef(false);

  const [newPack, setNewPack] = useState({ name: "" });
  const [newGear, setNewGear] = useState(blankNewGear);

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
  const [libraryCategory, setLibraryCategory] = useState(null);
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
  // Add-to-pack modal: the gear being added, the pack chosen (step 2), and the
  // new-category input.
  const [addToPackGear, setAddToPackGear] = useState(null);
  const [addToPackPackId, setAddToPackPackId] = useState(null);
  const [addToPackNewCat, setAddToPackNewCat] = useState("");
  // Pack cover crop: cropSource holds the raw selected image (data URL) while the
  // crop modal is open; croppedPx is the last region react-easy-crop reported.
  const [cropSource, setCropSource] = useState("");
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [cropZoom, setCropZoom] = useState(1);
  const [croppedPx, setCroppedPx] = useState(null);
  const [savingCover, setSavingCover] = useState(false);
  const coverInputRef = useRef(null);
  const [categoryDragSource, setCategoryDragSource] = useState(null);
  const [categoryDragOver, setCategoryDragOver] = useState(null);
  // Sidebar pack reordering (drag a card onto another to move it there).
  const [packDragId, setPackDragId] = useState(null);
  const [packDragOverId, setPackDragOverId] = useState(null);
  // Sidebar pack hover preview (the pack being hovered + cursor position).
  const [hoverPack, setHoverPack] = useState(null);
  const [hoverPos, setHoverPos] = useState({ x: 0, y: 0 });
  // Back-to-top button: shown once the page is scrolled down a bit.
  const [showTop, setShowTop] = useState(false);
  // Whether the tabs row is currently pinned at the top (drives frosted glass).
  const [navStuck, setNavStuck] = useState(false);
  const navRef = useRef(null);
  // Narrow/mobile is always single-column (sidebar stacks on top and scrolls
  // away), so the frosted glass should apply there regardless of sidebar state.
  const [isNarrow, setIsNarrow] = useState(
    () => typeof window !== "undefined" && window.matchMedia("(max-width: 980px)").matches
  );
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
    const onScroll = () => {
      setShowTop(window.scrollY > 500);
      const el = navRef.current;
      // Pinned once the sticky row reaches the top (rect.top clamps at 0).
      setNavStuck(el ? el.getBoundingClientRect().top <= 0.5 : false);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    onScroll();
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    const mq = window.matchMedia("(max-width: 980px)");
    const onChange = () => setIsNarrow(mq.matches);
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);

  useEffect(() => {
    setSelectedCategory(null);
    setSelectedWeightType(null);
    setSelectedMark(null);
    setNewCategories([]);
  }, [activePackId]);

  useEffect(() => {
    const serialized = JSON.stringify({ gears, packs, packItems, trips });
    let ts = updatedAtRef.current;
    if (serialized !== lastSavedRef.current) {
      // Real change: bump the timestamp (or keep a just-applied cloud one).
      lastSavedRef.current = serialized;
      ts = appliedUpdatedAt.current || new Date().toISOString();
      appliedUpdatedAt.current = null;
      updatedAtRef.current = ts;
      setUpdatedAt(ts);
    }
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ schemaVersion: SCHEMA_VERSION, gears, packs, packItems, trips, updatedAt: ts })
    );
  }, [gears, packs, packItems, trips]);

  // Persist the cold tracks map. Returns false (and leaves the previous value
  // intact) on quota failure, so callers can abort a track import transactionally.
  function persistTracks(nextTracks) {
    try {
      const body = JSON.stringify(nextTracks);
      if (body.length > MAX_TRACK_STORAGE_BYTES) {
        window.alert(
          `Track store too large (~${Math.round(body.length / 1024)} KB, limit ${Math.round(
            MAX_TRACK_STORAGE_BYTES / 1024
          )} KB). Import cancelled.`
        );
        return false;
      }
      localStorage.setItem(TRACKS_KEY, body);
      return true;
    } catch (e) {
      window.alert("Storage is full — the track is too large to save. Import cancelled.");
      return false;
    }
  }

  function applyCloud(cloud) {
    const applied = applyPortableBundle(cloud);
    const norm = applied ? applied.doc : { ...defaultData(), updatedAt: new Date().toISOString() };
    const nextTracks = applied ? applied.tracks : {};
    // Write the pulled tracks first so the doc never references a missing asset;
    // if it throws, useGoogleSync resets skipNextPush and surfaces the error.
    localStorage.setItem(TRACKS_KEY, JSON.stringify(nextTracks));
    appliedUpdatedAt.current = norm.updatedAt || new Date().toISOString();
    setGears(norm.gears);
    setPacks(norm.packs);
    setPackItems(norm.packItems);
    setTracks(nextTracks);
    setTrips(norm.trips);
    setActivePackId((prev) => (norm.packs.some((pack) => pack.id === prev) ? prev : norm.packs[0]?.id || ""));
    setActiveTripId((prev) => (norm.trips.some((trip) => trip.id === prev) ? prev : norm.trips[0]?.id || ""));
  }

  const sync = useGoogleSync({
    buildData: () =>
      buildPortableBundle({ schemaVersion: SCHEMA_VERSION, gears, packs, packItems, trips, updatedAt }, tracks),
    applyCloud,
    updatedAt
  });

  useEffect(() => {
    localStorage.setItem("ulpacker.settings", JSON.stringify({ hideZeroQty, sidebarOpen, showPrice }));
  }, [hideZeroQty, sidebarOpen, showPrice]);

  // Unlink trips from a pack that no longer exists (does not delete the trip).
  useEffect(() => {
    const validPackIds = new Set(packs.map((pack) => pack.id));
    setTrips((prev) => {
      let changed = false;
      const next = prev.map((trip) => {
        if (trip.packId && !validPackIds.has(trip.packId)) {
          changed = true;
          return { ...trip, packId: "" };
        }
        return trip;
      });
      return changed ? next : prev;
    });
  }, [packs]);

  // --- Trip CRUD ---------------------------------------------------------

  function persistedStats(track) {
    const s = buildTrackStats(track.segments);
    return {
      distanceM: s.distanceM,
      ascentM: s.ascentM,
      descentM: s.descentM,
      minEle: s.minEle,
      maxEle: s.maxEle,
      elevationCoverage: s.elevationCoverage,
      metricsVersion: s.metricsVersion
    };
  }

  function makeTrackRef(trackId, track, revision) {
    return {
      id: trackId,
      revision,
      pointCount: track.segments.reduce((n, seg) => n + seg.points.length, 0),
      sizeBytes: JSON.stringify(track).length,
      segmentCount: track.segments.length
    };
  }

  // Import a chosen candidate as a new trip (transactional: tracks first).
  function createTripFromTrack({ name, track, checkpoints = [] }) {
    if (trips.length >= MAX_TRIPS) {
      window.alert(`You can have at most ${MAX_TRIPS} trips.`);
      return;
    }
    const trackId = `trk_${id()}`;
    const nextTracks = { ...tracks, [trackId]: track };
    if (!persistTracks(nextTracks)) return;
    const trip = {
      id: `trip_${id()}`,
      name: name || "Untitled trip",
      description: "",
      packId: "",
      createdAt: new Date().toISOString(),
      trackRef: makeTrackRef(trackId, track, 1),
      stats: persistedStats(track),
      checkpoints
    };
    setTracks(nextTracks);
    setTrips((prev) => [...prev, trip]);
    setActiveTripId(trip.id);
    setView("trips");
  }

  // Replace a trip's track with a new immutable asset (add → swap → GC old).
  function replaceTripTrack(tripId, { track, checkpoints }) {
    const target = trips.find((t) => t.id === tripId);
    if (!target) return;
    const trackId = `trk_${id()}`;
    const withNew = { ...tracks, [trackId]: track };
    if (!persistTracks(withNew)) return;
    const nextTrips = trips.map((t) =>
      t.id === tripId
        ? {
            ...t,
            trackRef: makeTrackRef(trackId, track, (t.trackRef?.revision || 1) + 1),
            stats: persistedStats(track),
            checkpoints: checkpoints || t.checkpoints
          }
        : t
    );
    const gced = gcTracks(nextTrips, withNew);
    persistTracks(gced);
    setTracks(gced);
    setTrips(nextTrips);
  }

  function deleteTrip(tripId) {
    const nextTrips = trips.filter((t) => t.id !== tripId);
    setTrips(nextTrips);
    // Doc-first ordering: state update persists the doc; then GC orphaned assets.
    const gced = gcTracks(nextTrips, tracks);
    persistTracks(gced);
    setTracks(gced);
    setActiveTripId((prev) => (prev === tripId ? nextTrips[0]?.id || "" : prev));
  }

  function updateTrip(tripId, patch) {
    setTrips((prev) => prev.map((t) => (t.id === tripId ? { ...t, ...patch } : t)));
  }

  function setTripCheckpoints(tripId, updater) {
    setTrips((prev) =>
      prev.map((t) => (t.id === tripId ? { ...t, checkpoints: updater(t.checkpoints) } : t))
    );
  }

  const sortCheckpoints = (list) =>
    [...list].sort(
      (a, b) =>
        a.anchor.segmentIndex - b.anchor.segmentIndex || a.anchor.alongSegmentM - b.anchor.alongSegmentM
    );

  // Parse a GPX file and open the staged preview modal.
  async function openGpxImport(file, mode = "create", tripId = null) {
    if (!file) return;
    if (file.size > MAX_GPX_BYTES) {
      window.alert("GPX file is too large.");
      return;
    }
    try {
      const parsed = parseGpx(await file.text());
      if (parsed.candidates.length === 0) {
        window.alert(parsed.warnings.join("\n") || "No track or route found in this file.");
        return;
      }
      setGpxImport({ mode, tripId, fileName: file.name.replace(/\.gpx$/i, ""), ...parsed });
    } catch (e) {
      window.alert(e.message || "Could not read the GPX file.");
    }
  }

  // Commit the staged import: merge the chosen candidates' segments in file
  // order (gaps between tracks stay segment breaks, never phantom distance).
  function confirmGpxImport({ candidateIds, importWaypoints, addBoundaries }) {
    const gi = gpxImport;
    if (!gi) return;
    const ids = new Set(candidateIds || []);
    const chosen = gi.candidates.filter((c) => ids.has(c.id));
    if (chosen.length === 0) return;
    // Record each track's route distance BEFORE fusing (fusion preserves total
    // distance, so these boundary offsets stay valid on the fused track).
    const preCums = buildCumulatives(chosen.flatMap((c) => c.segments));
    const boundaryRouteM = [];
    let segCursor = 0;
    chosen.forEach((c, i) => {
      if (i > 0) boundaryRouteM.push({ routeM: preCums.segmentOffsets[segCursor], endsName: chosen[i - 1].name });
      segCursor += c.segments.length;
    });
    // Fuse touching segments (contiguous OSM ways) so a split route doesn't show
    // phantom gaps; genuinely separate segments stay separate.
    let segments = joinContiguousSegments(chosen.flatMap((c) => c.segments));
    if (segments.length > MAX_SEGMENTS) {
      window.alert(`Combined track has ${segments.length} segments; keeping the first ${MAX_SEGMENTS}.`);
      segments = segments.slice(0, MAX_SEGMENTS);
    }
    const track = { segments };
    const cums = buildCumulatives(track.segments);

    let checkpoints = [];
    if (importWaypoints && gi.waypoints.length) {
      checkpoints = gi.waypoints.map((wp) => ({
        id: `cp_${id()}`,
        name: wp.name,
        note: "",
        overnight: false,
        source: "waypoint",
        anchor: snapToTrack(track.segments, wp.lat, wp.lng, { cumulatives: cums })
      }));
    }

    // One overnight checkpoint at each track boundary, named after the stage that
    // ends there (destination-style naming is common; the user can rename).
    if (addBoundaries) {
      for (const b of boundaryRouteM) {
        if (b.routeM <= 1 || b.routeM >= cums.totalM - 1) continue;
        checkpoints.push({
          id: `cp_${id()}`,
          name: b.endsName,
          note: "",
          overnight: true,
          source: "manual",
          anchor: anchorAtRouteM(track.segments, cums, b.routeM)
        });
      }
    }

    if (gi.mode === "replace" && gi.tripId) {
      const existing = trips.find((t) => t.id === gi.tripId);
      const resnapped = (existing?.checkpoints || []).map((cp) => ({
        ...cp,
        anchor: snapToTrack(track.segments, cp.anchor.sourceLat, cp.anchor.sourceLng, {
          cumulatives: cums,
          preferRouteM: cp.anchor.routeDistanceM
        })
      }));
      replaceTripTrack(gi.tripId, { track, checkpoints: sortCheckpoints([...resnapped, ...checkpoints]) });
    } else {
      // Single track → use its name; multiple merged → use the file name.
      const name = chosen.length === 1 ? chosen[0].name || gi.fileName : gi.fileName;
      createTripFromTrack({ name, track, checkpoints: sortCheckpoints(checkpoints) });
    }
    setGpxImport(null);
  }

  const activeTrip = trips.find((t) => t.id === activeTripId) || null;
  const activeTripTrack = activeTrip ? tracks[activeTrip.trackRef?.id] || null : null;

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
      if (libraryCategory && !(gear.categories || []).includes(libraryCategory)) return false;
      if (!q) return true;
      const categories = (gear.categories || []).join(" ");
      return normalizeText(`${gear.name} ${gear.itemType} ${gear.description} ${categories}`).includes(q);
    });
  }, [gears, libraryQuery, libraryMark, libraryCategory]);

  // Library sidebar: overview stats + category counts (a gear can be in several
  // categories, so it's counted under each).
  const libraryStats = useMemo(() => {
    const cats = new Set();
    let variants = 0;
    gears.forEach((gear) => {
      variants += gear.variants?.length || 0;
      (gear.categories || []).forEach((c) => cats.add(c));
    });
    return { items: gears.length, variants, categories: cats.size };
  }, [gears]);

  const libraryCategories = useMemo(() => {
    const counts = new Map();
    gears.forEach((gear) => {
      (gear.categories || []).forEach((c) => counts.set(c, (counts.get(c) || 0) + 1));
    });
    return [...counts.entries()]
      .map(([cat, count]) => ({ cat, count }))
      .sort((a, b) => b.count - a.count || a.cat.localeCompare(b.cat));
  }, [gears]);

  function createPack(e) {
    e.preventDefault();
    if (!newPack.name.trim()) return;
    if (packs.length >= MAX_PACKS) return;
    const pack = {
      id: id(),
      name: newPack.name.trim(),
      description: "",
      image: "",
      createdAt: new Date().toISOString(),
      categoryOrder: []
    };
    setPacks((prev) => [pack, ...prev]);
    setActivePackId(pack.id);
    setNewPack({ name: "" });
  }

  function updateActivePack(patch) {
    if (!activePack) return;
    setPacks((prev) => prev.map((pack) => (pack.id === activePack.id ? { ...pack, ...patch } : pack)));
  }

  function onCoverFileSelected(e) {
    const file = e.target.files?.[0];
    e.target.value = ""; // allow re-selecting the same file later
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      setCrop({ x: 0, y: 0 });
      setCropZoom(1);
      setCroppedPx(null);
      setCropSource(String(reader.result || ""));
    };
    reader.readAsDataURL(file);
  }

  function closeCropModal() {
    setCropSource("");
    setCroppedPx(null);
    setSavingCover(false);
  }

  async function saveCover() {
    if (!cropSource || !croppedPx) return;
    setSavingCover(true);
    try {
      const dataUrl = await getCroppedImg(cropSource, croppedPx);
      updateActivePack({ image: dataUrl });
      closeCropModal();
    } catch {
      setSavingCover(false);
      window.alert("Sorry, that image could not be processed. Please try another file.");
    }
  }

  // Weight totals for any pack (by id): base / consumable / worn, plus derived
  // carried (base + consumable) and total (everything).
  function computePackWeights(packId) {
    let base = 0;
    let consumable = 0;
    let worn = 0;
    for (const item of packItems) {
      if (item.packId !== packId) continue;
      const grams =
        Math.max(0, parseNumber(item.quantity, 0)) * Math.max(0, parseNumber(item.weight, 0));
      if (item.weightType === "consumable") consumable += grams;
      else if (item.weightType === "worn") worn += grams;
      else base += grams;
    }
    const total = base + consumable + worn;
    return { base, consumable, worn, total, carried: base + consumable };
  }

  function reorderPacks(targetId) {
    const sourceId = packDragId;
    setPackDragId(null);
    setPackDragOverId(null);
    if (!sourceId || sourceId === targetId) return;
    setPacks((prev) => {
      const from = prev.findIndex((p) => p.id === sourceId);
      const to = prev.findIndex((p) => p.id === targetId);
      if (from < 0 || to < 0) return prev;
      return reorder(prev, from, to);
    });
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
    if (e) e.preventDefault();
    if (!newGear.name.trim()) return;
    const variants = newGear.variants.map((v) => ({
      id: id(),
      name: v.name.trim() || "Default",
      weight: Math.max(0, parseNumber(v.weight, 0)),
      price: Math.max(0, parseNumber(v.price, 0))
    }));
    setGears((prev) =>
      mergeOrCreateGear(prev, {
        id: id(),
        name: newGear.name.trim(),
        categories: normalizeCategories(newGear.categories),
        itemType: newGear.itemType.trim(),
        description: newGear.description.trim(),
        notes: "",
        variants
      }).gears
    );
    setNewGear(blankNewGear());
  }

  function discardNewGear() {
    setNewGear(blankNewGear());
  }

  function updateNewGearVariant(variantId, patch) {
    setNewGear((prev) => ({
      ...prev,
      variants: prev.variants.map((v) => (v.id === variantId ? { ...v, ...patch } : v))
    }));
  }

  function addNewGearVariant() {
    setNewGear((prev) =>
      prev.variants.length >= 9
        ? prev
        : {
            ...prev,
            variants: [
              ...prev.variants,
              { id: id(), name: `Variant ${prev.variants.length + 1}`, weight: "", price: "" }
            ]
          }
    );
  }

  function removeNewGearVariant(variantId) {
    setNewGear((prev) => ({
      ...prev,
      variants:
        prev.variants.length > 1 ? prev.variants.filter((v) => v.id !== variantId) : prev.variants
    }));
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
    // If the gear being removed is the one open in the add-to-pack modal, close it.
    setAddToPackGear((cur) => (cur?.id === gearId ? null : cur));
  }

  function updateGear(gearId, patch) {
    setGears((prev) => prev.map((gear) => (gear.id === gearId ? { ...gear, ...patch } : gear)));
  }

  function addVariant(gearId) {
    setGears((prev) =>
      prev.map((gear) =>
        gear.id === gearId && gear.variants.length < 9
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
    // Price is read live from the variant, but each pack item snapshots the
    // weight — so when the variant weight changes, push it to every pack item
    // using this variant so packs stay in sync.
    if (patch.weight !== undefined) {
      const nextWeight = Math.max(0, parseNumber(patch.weight, 0));
      setPackItems((prev) =>
        prev.map((item) =>
          item.gearId === gearId && item.variantId === variantId
            ? { ...item, weight: nextWeight }
            : item
        )
      );
    }
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

  function addToSpecificPack(gearId, packId, category) {
    const target = packs.find((pack) => pack.id === packId);
    if (!target) return;
    const gear = gears.find((item) => item.id === gearId);
    if (!gear || gear.variants.length === 0) return;
    const newItem = {
      id: id(),
      packId: target.id,
      gearId,
      variantId: gear.variants[0].id,
      category: (category || "").trim() || primaryCategory(gear),
      quantity: 1,
      weight: Math.max(0, parseNumber(gear.variants[0]?.weight, 0)),
      weightType: "base"
    };
    setPackItems((prev) => [...prev, newItem]);
  }

  function openAddToPack(gear) {
    setAddToPackGear(gear);
    setAddToPackPackId(null);
    setAddToPackNewCat("");
  }

  function closeAddToPack() {
    setAddToPackGear(null);
    setAddToPackPackId(null);
    setAddToPackNewCat("");
  }

  function confirmAddToPack(category) {
    const cat = (category || "").trim();
    if (!addToPackGear || !addToPackPackId || !cat) return;
    addToSpecificPack(addToPackGear.id, addToPackPackId, cat);
    closeAddToPack();
  }

  // Category choices for the add-to-pack modal: the item's own categories first
  // (highest priority), then the chosen pack's existing categories (deduped).
  const addToPackCategories = (() => {
    if (!addToPackGear || !addToPackPackId) return { item: [], pack: [] };
    const item = addToPackGear.categories || [];
    const seen = new Set(item);
    const pack = [];
    const target = packs.find((p) => p.id === addToPackPackId);
    const push = (c) => {
      if (c && !seen.has(c)) {
        seen.add(c);
        pack.push(c);
      }
    };
    (target?.categoryOrder || []).forEach(push);
    packItems.forEach((it) => {
      if (it.packId === addToPackPackId) push(it.category);
    });
    return { item, pack };
  })();

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
    const bundle = buildPortableBundle(
      { schemaVersion: SCHEMA_VERSION, gears, packs, packItems, trips, updatedAt },
      tracks
    );
    const blob = new Blob([JSON.stringify(bundle, null, 2)], {
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
      const applied = applyPortableBundle(JSON.parse(await file.text()));
      if (!applied) {
        window.alert("Invalid backup file.");
        return;
      }
      if (!window.confirm("Replace all current gear, packs, and trips with the data from this file?")) return;
      // Persist tracks first so the doc never references a missing asset.
      if (!persistTracks(applied.tracks)) return;
      const { doc } = applied;
      appliedUpdatedAt.current = new Date().toISOString();
      setGears(doc.gears);
      setPacks(doc.packs);
      setPackItems(doc.packItems);
      setTracks(applied.tracks);
      setTrips(doc.trips);
      setActivePackId(doc.packs[0]?.id || "");
      setActiveTripId(doc.trips[0]?.id || "");
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
            <div className="menu account-menu">
              <button type="button" className="menu-trigger account-trigger">
                {sync.account?.picture ? (
                  <img
                    className="account-avatar"
                    src={sync.account.picture}
                    alt=""
                    referrerPolicy="no-referrer"
                  />
                ) : sync.account ? (
                  <span className="account-avatar account-avatar-fallback">
                    {(sync.account.name || "?").charAt(0).toUpperCase()}
                  </span>
                ) : (
                  <span className="account-avatar account-avatar-fallback">
                    <UserIcon />
                  </span>
                )}
                {sync.account && (
                  <span className={`sync-dot sync-${sync.status}`} title={syncLabel(sync.status)} />
                )}
              </button>
              <div className="menu-list account-list">
                {sync.account ? (
                  <div className="account-info">
                    <strong>{sync.account.name}</strong>
                    <small>{sync.account.email}</small>
                    <small className={`sync-line sync-line-${sync.status}`}>{syncLabel(sync.status)}</small>
                  </div>
                ) : sync.configured ? (
                  <button type="button" onClick={sync.signIn}>
                    Sign in
                  </button>
                ) : null}
                {sync.account && (sync.status === "permission" || sync.status === "error") && (
                  <button type="button" onClick={sync.signIn}>
                    Reconnect Drive
                  </button>
                )}
                {/* account-info already carries a bottom border; only add a
                    divider in the signed-out case to separate Sign in above. */}
                {!sync.account && sync.configured && <div className="menu-divider" />}
                <button type="button" onClick={exportBackup}>
                  Export Profile
                </button>
                <label className="menu-file">
                  Import Profile
                  <input type="file" accept=".json,application/json" onChange={importBackup} />
                </label>
                {sync.account && (
                  <button type="button" onClick={sync.signOut}>
                    Sign out
                  </button>
                )}
              </div>
            </div>
          </div>
        </div>
      </header>

      {/* Sits OUTSIDE the header so its sticky containing block is .app (full
          page height), not the short header — otherwise it unpins once the
          header scrolls past. `with-sidebar` narrows the pinned bar to the
          sidebar column so it doesn't cover the pack view on the right. */}
      <div
        ref={navRef}
        className={`nav-row ${sidebarOpen ? "with-sidebar" : ""} ${
          navStuck && (isNarrow || !sidebarOpen) ? "frosted" : ""
        }`}
      >
        <button
          type="button"
          className={`sidebar-toggle ${sidebarOpen ? "active" : ""}`}
          onClick={() => setSidebarOpen((open) => !open)}
          title={sidebarOpen ? "Hide sidebar" : "Show sidebar"}
          aria-label="Toggle sidebar"
          aria-pressed={sidebarOpen}
        >
          <PanelIcon />
        </button>
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
          <button
            type="button"
            className={view === "trips" ? "active" : ""}
            onClick={() => setView("trips")}
          >
            Trips
          </button>
        </div>
      </div>

      <main className={`dashboard ${!sidebarOpen ? "library-layout" : ""}`}>
        {view === "library" && sidebarOpen && (
        <aside className="panel packs-panel library-side">
          <div className="panel-head">
            <h2>Library</h2>
            <span>{libraryStats.items} items</span>
          </div>

          <div className="lib-stats">
            <div className="lib-stat">
              <span>Items</span>
              <strong>{libraryStats.items}</strong>
            </div>
            <div className="lib-stat">
              <span>Variants</span>
              <strong>{libraryStats.variants}</strong>
            </div>
            <div className="lib-stat">
              <span>Categories</span>
              <strong>{libraryStats.categories}</strong>
            </div>
          </div>

          <div className="lib-cats-head">Categories</div>
          <div className="lib-cats">
            <button
              type="button"
              className={`lib-cat ${!libraryCategory ? "active" : ""}`}
              onClick={() => setLibraryCategory(null)}
            >
              <span>All</span>
              <em>{libraryStats.items}</em>
            </button>
            {libraryCategories.map(({ cat, count }) => (
              <button
                type="button"
                key={cat}
                className={`lib-cat ${libraryCategory === cat ? "active" : ""}`}
                onClick={() => setLibraryCategory((cur) => (cur === cat ? null : cat))}
              >
                <span>{cat}</span>
                <em>{count}</em>
              </button>
            ))}
          </div>
        </aside>
        )}

        {view === "packs" && sidebarOpen && (
        <aside className="panel packs-panel">
          <div className="panel-head">
            <h2>Packs</h2>
            <span>{packs.length} / {MAX_PACKS}</span>
          </div>

          <form className="new-pack-form" onSubmit={createPack}>
            <input
              placeholder="Pack name"
              value={newPack.name}
              onChange={(e) => setNewPack({ name: e.target.value })}
              disabled={packs.length >= MAX_PACKS}
            />
            <button type="submit" disabled={packs.length >= MAX_PACKS}>
              Create Pack
            </button>
            {packs.length >= MAX_PACKS && (
              <p className="pack-limit-note">Pack limit reached ({MAX_PACKS}).</p>
            )}
          </form>

          <div className="pack-cards">
            {packs.map((pack) => {
              const w = computePackWeights(pack.id);
              // Range shown on the card: (total − consumable) … total — i.e. the
              // pack weight once consumables are eaten, up to fully loaded.
              const weightRange = `${((w.total - w.consumable) / 1000).toFixed(2)} - ${(
                w.total / 1000
              ).toFixed(2)} kg`;

              return (
                <div
                  className={`pack-card-wrap ${packDragId === pack.id ? "dragging" : ""} ${
                    packDragOverId === pack.id && packDragId !== pack.id ? "drag-over" : ""
                  }`}
                  key={pack.id}
                  draggable
                  onDragStart={(e) => {
                    setPackDragId(pack.id);
                    setHoverPack(null);
                    e.dataTransfer.effectAllowed = "move";
                    // Firefox requires data to be set for a drag to start.
                    e.dataTransfer.setData("text/plain", pack.id);
                  }}
                  onDragOver={(e) => {
                    if (!packDragId) return;
                    e.preventDefault();
                    setPackDragOverId(pack.id);
                  }}
                  onDragLeave={() =>
                    setPackDragOverId((cur) => (cur === pack.id ? null : cur))
                  }
                  onDrop={(e) => {
                    e.preventDefault();
                    reorderPacks(pack.id);
                  }}
                  onDragEnd={() => {
                    setPackDragId(null);
                    setPackDragOverId(null);
                  }}
                  onMouseEnter={(e) => {
                    if (packDragId) return;
                    setHoverPack(pack);
                    setHoverPos({ x: e.clientX, y: e.clientY });
                  }}
                  onMouseMove={(e) => {
                    if (packDragId) return;
                    setHoverPos({ x: e.clientX, y: e.clientY });
                  }}
                  onMouseLeave={() => setHoverPack((cur) => (cur?.id === pack.id ? null : cur))}
                >
                  <button
                    type="button"
                    className={`pack-card ${activePack?.id === pack.id ? "active" : ""} ${pack.image ? "has-image" : ""}`}
                    style={pack.image ? { "--pack-img": `url(${pack.image})` } : undefined}
                    onClick={() => setActivePackId(pack.id)}
                  >
                    <strong>{pack.name}</strong>
                    <small>{pack.description || "No description"}</small>
                    <span>{weightRange}</span>
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

        {view === "trips" && sidebarOpen && (
          <TripsSidebar
            trips={trips}
            packs={packs}
            activeTripId={activeTripId}
            onSelect={setActiveTripId}
            onDelete={deleteTrip}
            onImportGpx={(file) => openGpxImport(file, "create")}
          />
        )}

        <section className={`panel workspace ${!sidebarOpen ? "centered" : ""}`}>
          {view === "library" && (
            <>
              <div className="panel-head">
                <h2>Gear Library</h2>
                <span>
                  {filteredGears.length === gears.length
                    ? `${gears.length} items`
                    : `${filteredGears.length} of ${gears.length}`}
                </span>
              </div>

              <section className="library-create">
                <div className="ng-head">
                  <button
                    type="button"
                    className={`add-gear-toggle ${addGearOpen ? "open" : ""}`}
                    onClick={() => setAddGearOpen((open) => !open)}
                    aria-expanded={addGearOpen}
                  >
                    <PlusIcon />
                    <span>Add New Gear</span>
                  </button>
                  {addGearOpen && (
                    <div className="ng-actions">
                      <button
                        type="button"
                        className="ng-discard"
                        title="Discard"
                        aria-label="Discard"
                        onClick={discardNewGear}
                      >
                        <XIcon />
                      </button>
                      <button
                        type="button"
                        className="ng-accept"
                        title="Add gear"
                        aria-label="Add gear"
                        disabled={!newGear.name.trim()}
                        onClick={() => addGear()}
                      >
                        <CheckIcon />
                      </button>
                    </div>
                  )}
                </div>
                {addGearOpen && (
                <form className="new-gear-form" onSubmit={addGear}>
                  <div className="ng-grid">
                    <input
                      className="ng-input"
                      placeholder="Name"
                      value={newGear.name}
                      onChange={(e) => setNewGear((prev) => ({ ...prev, name: e.target.value }))}
                    />
                    <input
                      className="ng-input"
                      placeholder="Description"
                      value={newGear.description}
                      onChange={(e) => setNewGear((prev) => ({ ...prev, description: e.target.value }))}
                    />
                    <input
                      className="ng-input"
                      placeholder="Item type"
                      value={newGear.itemType}
                      onChange={(e) => setNewGear((prev) => ({ ...prev, itemType: e.target.value }))}
                    />
                    <div className="ng-cat">
                      <CategoryChipsInput
                        categories={newGear.categories}
                        onChange={(next) => setNewGear((prev) => ({ ...prev, categories: next }))}
                        placeholder="Add category"
                      />
                    </div>
                  </div>

                  <div className="variant-editor ng-variants">
                    {newGear.variants.map((variant) => (
                      <div className="variant-chip" key={variant.id}>
                        <input
                          className="variant-name"
                          placeholder="Variant"
                          value={variant.name}
                          onChange={(e) => updateNewGearVariant(variant.id, { name: e.target.value })}
                        />
                        <label className="variant-field">
                          <input
                            type="number"
                            min="0"
                            className="variant-num"
                            placeholder="0"
                            value={variant.weight}
                            onChange={(e) => updateNewGearVariant(variant.id, { weight: e.target.value })}
                          />
                          <span>g</span>
                        </label>
                        <label className="variant-field">
                          <input
                            type="number"
                            min="0"
                            className="variant-num"
                            placeholder="0"
                            value={variant.price}
                            onChange={(e) => updateNewGearVariant(variant.id, { price: e.target.value })}
                          />
                          <span>{CURRENCY}</span>
                        </label>
                        <button
                          type="button"
                          className="variant-remove"
                          title="Remove variant"
                          aria-label="Remove variant"
                          disabled={newGear.variants.length <= 1}
                          onClick={() => removeNewGearVariant(variant.id)}
                        >
                          ×
                        </button>
                      </div>
                    ))}
                    <button
                      type="button"
                      className="variant-add"
                      disabled={newGear.variants.length >= 9}
                      onClick={addNewGearVariant}
                    >
                      + Variant
                    </button>
                  </div>
                </form>
                )}
              </section>

              <section className="library-list">
                <div className="library-toolbar">
                  <div className="search-box">
                    <SearchIcon />
                    <input
                      value={libraryQuery}
                      onChange={(e) => setLibraryQuery(e.target.value)}
                      placeholder="Search by name, category, type"
                    />
                    {libraryQuery && (
                      <button
                        type="button"
                        className="search-clear"
                        title="Clear search"
                        aria-label="Clear search"
                        onClick={() => setLibraryQuery("")}
                      >
                        <XIcon />
                      </button>
                    )}
                  </div>
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
                    <article key={gear.id} className="gear-row">
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
                      <button
                        type="button"
                        className={`variant-toggle ${gear.variants.length > 1 ? "variant-toggle-many" : ""}`}
                        onClick={() => toggleGearExpanded(gear.id)}
                      >
                        {gear.variants.length}
                        <span className="variant-word">
                          {" "}
                          {gear.variants.length === 1 ? "variant" : "variants"}
                        </span>
                      </button>
                      <div className="library-actions">
                        <button
                          type="button"
                          className="add-to-pack"
                          title="Add to Pack"
                          aria-label="Add to Pack"
                          onClick={() => openAddToPack(gear)}
                        >
                          <PlusIcon />
                          <BackpackIcon />
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
                            <div className="variant-chip" key={variant.id}>
                              <input
                                className="variant-name"
                                value={variant.name}
                                onChange={(e) => updateVariant(gear.id, variant.id, { name: e.target.value })}
                              />
                              <label className="variant-field">
                                <input
                                  type="number"
                                  min="0"
                                  className="variant-num"
                                  value={variant.weight}
                                  onChange={(e) =>
                                    updateVariant(gear.id, variant.id, {
                                      weight: Math.max(0, parseNumber(e.target.value, 0))
                                    })
                                  }
                                />
                                <span>g</span>
                              </label>
                              <label className="variant-field">
                                <input
                                  type="number"
                                  min="0"
                                  className="variant-num"
                                  value={Math.max(0, parseNumber(variant.price, 0))}
                                  onChange={(e) =>
                                    updateVariant(gear.id, variant.id, {
                                      price: Math.max(0, parseNumber(e.target.value, 0))
                                    })
                                  }
                                />
                                <span>{CURRENCY}</span>
                              </label>
                              <button
                                type="button"
                                className="variant-remove"
                                title="Remove variant"
                                aria-label="Remove variant"
                                disabled={gear.variants.length <= 1}
                                onClick={() => removeVariant(gear.id, variant.id)}
                              >
                                ×
                              </button>
                            </div>
                          ))}
                          <button
                            type="button"
                            className="variant-add"
                            disabled={gear.variants.length >= 9}
                            onClick={() => addVariant(gear.id)}
                          >
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
                <div className="workspace-titles">
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
                </div>
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
                      <div className="menu-divider" />
                      <button type="button" onClick={exportPackCsv}>
                        Export to CSV
                      </button>
                    </div>
                  </div>
                  <button type="button" className="action-danger" onClick={deleteActivePack}>
                    <TrashIcon />
                    Delete
                  </button>
                </div>
              </div>

              <input
                ref={coverInputRef}
                type="file"
                accept="image/*"
                style={{ display: "none" }}
                onChange={onCoverFileSelected}
              />
              {activePack.image ? (
                <div className="pack-cover">
                  <img src={activePack.image} alt={`${activePack.name} cover`} />
                  <div className="pack-cover-actions">
                    <button
                      type="button"
                      title="Change cover image"
                      aria-label="Change cover image"
                      onClick={() => coverInputRef.current?.click()}
                    >
                      <PencilIcon />
                    </button>
                    <button
                      type="button"
                      className="cover-remove"
                      title="Remove cover image"
                      aria-label="Remove cover image"
                      onClick={() => updateActivePack({ image: "" })}
                    >
                      <TrashIcon />
                    </button>
                  </div>
                </div>
              ) : (
                <button
                  type="button"
                  className="pack-cover-empty"
                  onClick={() => coverInputRef.current?.click()}
                >
                  <ImageIcon />
                  Add cover image
                </button>
              )}

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
                              onDragEnd={() => setDragOverIndex(null)}
                              onDragOver={(e) => {
                                e.preventDefault();
                                setDragOverIndex(index);
                              }}
                            >
                              <span
                                className="drag-handle cell-drag"
                                title="Drag to reorder"
                                draggable
                                onDragStart={(e) =>
                                  e.dataTransfer.setData(
                                    "application/json",
                                    JSON.stringify({ type: "pack", itemId: row.id })
                                  )
                                }
                              >
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

                  {cropSource && (
                    <div className="modal-overlay" onClick={closeCropModal}>
                      <div className="modal-panel" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-head">
                          <h3>Crop cover image</h3>
                          <button type="button" onClick={closeCropModal}>
                            ✕
                          </button>
                        </div>
                        <div className="crop-stage">
                          <Cropper
                            image={cropSource}
                            crop={crop}
                            zoom={cropZoom}
                            aspect={COVER_ASPECT}
                            onCropChange={setCrop}
                            onZoomChange={setCropZoom}
                            onCropComplete={(_, px) => setCroppedPx(px)}
                          />
                        </div>
                        <div className="crop-controls">
                          <label className="crop-zoom">
                            Zoom
                            <input
                              type="range"
                              min={1}
                              max={3}
                              step={0.01}
                              value={cropZoom}
                              onChange={(e) => setCropZoom(Number(e.target.value))}
                            />
                          </label>
                          <div className="crop-actions">
                            <button type="button" onClick={closeCropModal}>
                              Cancel
                            </button>
                            <button
                              type="button"
                              className="crop-save"
                              disabled={!croppedPx || savingCover}
                              onClick={saveCover}
                            >
                              {savingCover ? "Saving…" : "Save cover"}
                            </button>
                          </div>
                        </div>
                      </div>
                    </div>
                  )}

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

          {view === "trips" && (
            <TripWorkspace
              trip={activeTrip}
              track={activeTripTrack}
              packs={packs}
              onUpdateTrip={(patch) => activeTrip && updateTrip(activeTrip.id, patch)}
              onDeleteTrip={() => activeTrip && deleteTrip(activeTrip.id)}
              onReplaceGpx={(file) => activeTrip && openGpxImport(file, "replace", activeTrip.id)}
              onAddCheckpoint={(cp) =>
                activeTrip && setTripCheckpoints(activeTrip.id, (list) => sortCheckpoints([...list, cp]))
              }
              onUpdateCheckpoint={(cpId, patch) =>
                activeTrip &&
                setTripCheckpoints(activeTrip.id, (list) =>
                  list.map((c) => (c.id === cpId ? { ...c, ...patch } : c))
                )
              }
              onDeleteCheckpoint={(cpId) =>
                activeTrip && setTripCheckpoints(activeTrip.id, (list) => list.filter((c) => c.id !== cpId))
              }
            />
          )}
        </section>
      </main>
      {gpxImport && (
        <GpxImportModal
          data={gpxImport}
          onConfirm={confirmGpxImport}
          onClose={() => setGpxImport(null)}
        />
      )}
      {addToPackGear && (
        <div className="modal-overlay" onClick={closeAddToPack}>
          <div className="modal-panel add-to-pack-modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-head">
              <h3>
                {!addToPackPackId
                  ? `Add “${addToPackGear.name}” to…`
                  : "Choose a category"}
              </h3>
              <button type="button" onClick={closeAddToPack}>
                ✕
              </button>
            </div>

            {!addToPackPackId ? (
              <div className="add-pack-cards">
                {packs.map((pack) => {
                  const w = computePackWeights(pack.id);
                  const range = `${((w.total - w.consumable) / 1000).toFixed(2)} - ${(
                    w.total / 1000
                  ).toFixed(2)} kg`;
                  return (
                    <button
                      key={pack.id}
                      type="button"
                      className={`pack-card ${pack.image ? "has-image" : ""}`}
                      style={pack.image ? { "--pack-img": `url(${pack.image})` } : undefined}
                      onClick={() => setAddToPackPackId(pack.id)}
                    >
                      <strong>{pack.name}</strong>
                      <small>{pack.description || "No description"}</small>
                      <span>{range}</span>
                    </button>
                  );
                })}
              </div>
            ) : (
              <div className="add-cat-section">
                {addToPackCategories.item.length > 0 && (
                  <div className="add-cat-group">
                    <h4>Item category</h4>
                    <div className="add-cat-chips">
                      {addToPackCategories.item.map((c) => (
                        <button
                          key={c}
                          type="button"
                          className="add-cat-chip primary"
                          onClick={() => confirmAddToPack(c)}
                        >
                          {c}
                        </button>
                      ))}
                    </div>
                  </div>
                )}
                {addToPackCategories.pack.length > 0 && (
                  <div className="add-cat-group">
                    <h4>Pack categories</h4>
                    <div className="add-cat-chips">
                      {addToPackCategories.pack.map((c) => (
                        <button
                          key={c}
                          type="button"
                          className="add-cat-chip"
                          onClick={() => confirmAddToPack(c)}
                        >
                          {c}
                        </button>
                      ))}
                    </div>
                  </div>
                )}
                <form
                  className="add-cat-new"
                  onSubmit={(e) => {
                    e.preventDefault();
                    confirmAddToPack(addToPackNewCat);
                  }}
                >
                  <input
                    placeholder="New category"
                    value={addToPackNewCat}
                    onChange={(e) => setAddToPackNewCat(e.target.value)}
                  />
                  <button type="submit" disabled={!addToPackNewCat.trim()}>
                    Add
                  </button>
                </form>
              </div>
            )}
          </div>
        </div>
      )}
      {hoverPack && !packDragId && (
        <PackHoverPreview
          pack={hoverPack}
          pos={hoverPos}
          weights={computePackWeights(hoverPack.id)}
        />
      )}
      {showTop && (
        <button
          type="button"
          className="back-to-top"
          title="Back to top"
          aria-label="Back to top"
          onClick={() => window.scrollTo({ top: 0, behavior: "smooth" })}
        >
          <ArrowUpIcon />
        </button>
      )}
    </div>
  );
}
