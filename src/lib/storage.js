import { id, parseNumber, normalizeWeightType } from "./util.js";
import { normalizeCategories, normalizeVariants, normalizePurchase, mergeGears, primaryCategory } from "./gear.js";
import {
  buildTrackStats,
  buildCumulatives,
  clampText,
  isCheckpointKind,
  MAX_DAY_NOTE_LENGTH,
  MAX_DAY_NOTES,
  MAX_TRIPS,
  MAX_CHECKPOINTS_PER_TRIP,
  MAX_SEGMENTS,
  MAX_TRACK_POINTS,
  METRICS_VERSION
} from "./trail.js";

// v4 introduces `trips` + a separate tracks store. It uses a NEW local key and
// (in googleDrive.js) a NEW Drive file so an OLD client build — whose normalizer
// strips unknown keys — can never pull-then-push and wipe Trips via last-write-
// wins. v3 is read once for migration and then left untouched for rollback.
export const STORAGE_KEY = "ulpacker.v4";
export const LEGACY_STORAGE_KEY_V3 = "ulpacker.v3";
export const TRACKS_KEY = "ulpacker.tracks";
export const SCHEMA_VERSION = 4;

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

// Cover images must be inline data URLs (the app only ever produces those).
// Rejecting anything else keeps an imported backup from planting a remote URL
// that would be fetched on view (tracking / IP leak).
function sanitizeCoverImage(value) {
  return typeof value === "string" && value.startsWith("data:image/") ? value : "";
}

export function ensurePackDefaults(data) {
  const packs = Array.isArray(data.packs) && data.packs.length > 0
    ? data.packs.map((pack) => ({
        id: pack.id || id(),
        name: pack.name || "Unnamed Pack",
        description: pack.description || "",
        image: sanitizeCoverImage(pack.image),
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
          image: "",
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

// --- Tracks (cold store, keyed by immutable trackId) ---------------------

function sanitizeTrack(raw) {
  if (!raw || !Array.isArray(raw.segments)) return null;
  let budget = MAX_TRACK_POINTS;
  const segments = [];
  for (const seg of raw.segments.slice(0, MAX_SEGMENTS)) {
    if (!seg || !Array.isArray(seg.points)) continue;
    const points = [];
    for (const p of seg.points) {
      if (budget <= 0) break;
      if (!Array.isArray(p)) continue;
      const lat = Number(p[0]);
      const lng = Number(p[1]);
      if (!Number.isFinite(lat) || lat < -90 || lat > 90) continue;
      if (!Number.isFinite(lng) || lng < -180 || lng > 180) continue;
      const ele = Number.isFinite(Number(p[2])) ? Math.round(Number(p[2])) : null;
      points.push([lat, lng, ele]);
      budget -= 1;
    }
    if (points.length >= 2) segments.push({ points });
  }
  return segments.length > 0 ? { segments } : null;
}

// Normalize the whole tracks map; drops malformed assets.
export function sanitizeTracks(raw) {
  const out = {};
  if (!raw || typeof raw !== "object") return out;
  for (const [key, value] of Object.entries(raw)) {
    if (typeof key !== "string") continue;
    const track = sanitizeTrack(value);
    if (track) out[key] = track;
  }
  return out;
}

function sanitizeCheckpoint(raw) {
  if (!raw || typeof raw !== "object") return null;
  const a = raw.anchor || {};
  const segmentIndex = Number.isFinite(Number(a.segmentIndex)) ? Math.max(0, a.segmentIndex | 0) : 0;
  const alongSegmentM = Math.max(0, parseNumber(a.alongSegmentM, 0));
  const routeDistanceM = Math.max(0, parseNumber(a.routeDistanceM, 0));
  const lat = Number(a.lat);
  const lng = Number(a.lng);
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) return null;
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) return null;
  const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : null);
  // `kind` categorises the checkpoint (drives the map icon); "overnight" also
  // drives the itinerary. Migrate legacy `overnight: true` → kind "overnight".
  const kind = isCheckpointKind(raw.kind) ? raw.kind : raw.overnight ? "overnight" : "poi";
  return {
    id: raw.id || id(),
    name: clampText(raw.name),
    note: clampText(raw.note),
    kind,
    source: raw.source === "waypoint" ? "waypoint" : "manual",
    anchor: {
      segmentIndex,
      alongSegmentM,
      routeDistanceM,
      lat,
      lng,
      ele: num(a.ele) == null ? null : Math.round(num(a.ele)),
      offsetM: Math.max(0, Math.round(parseNumber(a.offsetM, 0))),
      sourceLat: num(a.sourceLat) == null ? lat : num(a.sourceLat),
      sourceLng: num(a.sourceLng) == null ? lng : num(a.sourceLng)
    }
  };
}

// Clamp a checkpoint's anchor to the actual track geometry (segment shorter than
// stored alongSegmentM, or missing segment). Recomputes routeDistanceM from the
// canonical cumulatives so cached values can't drift.
function resolveCheckpoints(checkpoints, track) {
  if (!track) return checkpoints;
  const { cumulativeBySegment, segmentOffsets, segmentLengths } = buildCumulatives(track.segments);
  const segCount = track.segments.length;
  return checkpoints.map((cp) => {
    const a = cp.anchor;
    const s = Math.min(a.segmentIndex, segCount - 1);
    const along = Math.min(a.alongSegmentM, segmentLengths[s] || 0);
    return {
      ...cp,
      anchor: { ...a, segmentIndex: s, alongSegmentM: along, routeDistanceM: (segmentOffsets[s] || 0) + along }
    };
  });
}

// Sanitize trips; when `tracks` is provided, resolve trackRef, recompute
// canonical stats from geometry (never trust cached), and re-clamp checkpoints.
// A trip whose trackRef.id has no asset is KEPT (rendered as "track missing").
export function normalizeTrips(rawTrips, validPackIds, tracks) {
  if (!Array.isArray(rawTrips)) return [];
  return rawTrips
    .slice(0, MAX_TRIPS)
    .map((raw) => {
      if (!raw || typeof raw !== "object") return null;
      const ref = raw.trackRef || {};
      const trackId = typeof ref.id === "string" ? ref.id : "";
      const track = tracks && trackId ? tracks[trackId] : null;

      let checkpoints = (Array.isArray(raw.checkpoints) ? raw.checkpoints : [])
        .slice(0, MAX_CHECKPOINTS_PER_TRIP)
        .map(sanitizeCheckpoint)
        .filter(Boolean);
      checkpoints = resolveCheckpoints(checkpoints, track)
        .sort((x, y) => x.anchor.segmentIndex - y.anchor.segmentIndex || x.anchor.alongSegmentM - y.anchor.alongSegmentM);

      let stats;
      let trackRef;
      if (track) {
        const s = buildTrackStats(track.segments);
        stats = {
          distanceM: s.distanceM, ascentM: s.ascentM, descentM: s.descentM,
          minEle: s.minEle, maxEle: s.maxEle, elevationCoverage: s.elevationCoverage,
          metricsVersion: METRICS_VERSION
        };
        trackRef = {
          id: trackId,
          revision: Math.max(1, parseNumber(ref.revision, 1)),
          pointCount: track.segments.reduce((n, seg) => n + seg.points.length, 0),
          sizeBytes: JSON.stringify(track).length,
          segmentCount: track.segments.length
        };
      } else {
        // No asset available (missing, or normalizing without the tracks map):
        // keep whatever the doc claims, sanitized.
        stats = {
          distanceM: Math.max(0, parseNumber(raw.stats?.distanceM, 0)),
          ascentM: raw.stats?.ascentM == null ? null : Math.max(0, parseNumber(raw.stats.ascentM, 0)),
          descentM: raw.stats?.descentM == null ? null : Math.max(0, parseNumber(raw.stats.descentM, 0)),
          minEle: raw.stats?.minEle == null ? null : parseNumber(raw.stats.minEle, 0),
          maxEle: raw.stats?.maxEle == null ? null : parseNumber(raw.stats.maxEle, 0),
          elevationCoverage: Math.max(0, Math.min(1, parseNumber(raw.stats?.elevationCoverage, 0))),
          metricsVersion: parseNumber(raw.stats?.metricsVersion, 0)
        };
        trackRef = {
          id: trackId,
          revision: Math.max(1, parseNumber(ref.revision, 1)),
          pointCount: Math.max(0, parseNumber(ref.pointCount, 0)),
          sizeBytes: Math.max(0, parseNumber(ref.sizeBytes, 0)),
          segmentCount: Math.max(0, parseNumber(ref.segmentCount, 0))
        };
      }

      // Segment-boundary route distances (potential day-split anchors). Clamp
      // to the track length when we have it; keep sorted + de-duped.
      const totalM = stats.distanceM;
      let boundaries = (Array.isArray(raw.boundaries) ? raw.boundaries : [])
        .map((n) => parseNumber(n, NaN))
        .filter((n) => Number.isFinite(n) && n > 1 && (!track || n < totalM - 1))
        .sort((a, b) => a - b)
        .slice(0, MAX_SEGMENTS);
      boundaries = boundaries.filter((n, i) => i === 0 || n - boundaries[i - 1] > 1);

      // Per-day Markdown descriptions, keyed by the boundary that starts the day
      // ("start" or a checkpoint id). Values are plain text — rendered as React
      // elements, never as HTML — but still capped.
      const rawNotes =
        raw.dayNotes && typeof raw.dayNotes === "object" && !Array.isArray(raw.dayNotes) ? raw.dayNotes : {};
      const dayNotes = {};
      let noteCount = 0;
      for (const [k, v] of Object.entries(rawNotes)) {
        if (noteCount >= MAX_DAY_NOTES) break;
        if (typeof k !== "string" || !k || typeof v !== "string" || !v) continue;
        dayNotes[k.slice(0, 64)] = v.slice(0, MAX_DAY_NOTE_LENGTH);
        noteCount += 1;
      }

      // Extra itinerary days that are NOT on the track (travel/approach, rest,
      // shuttle days). `before` is the boundary key of the real day they precede
      // ("start" = before day 1, "finish" = appended at the end).
      const extraDays = (Array.isArray(raw.extraDays) ? raw.extraDays : [])
        .slice(0, 30)
        .map((d) =>
          d && typeof d === "object"
            ? {
                id: d.id || id(),
                before: typeof d.before === "string" && d.before ? d.before.slice(0, 64) : "finish",
                title: clampText(d.title) || "Off-route day",
                note: typeof d.note === "string" ? d.note.slice(0, MAX_DAY_NOTE_LENGTH) : ""
              }
            : null
        )
        .filter(Boolean);

      // Itineraries that need a prep/arrival day number the first card "Day 0".
      const startDayNumber = parseNumber(raw.startDayNumber, 1) === 0 ? 0 : 1;

      const packId = raw.packId && validPackIds.has(raw.packId) ? raw.packId : "";
      return {
        id: raw.id || id(),
        name: clampText(raw.name) || "Untitled trip",
        description: clampText(raw.description),
        image: sanitizeCoverImage(raw.image),
        // Optional trailhead names for the virtual Start/Finish. Absent on older
        // trips → "" → the UI falls back to "Start"/"Finish".
        startName: clampText(raw.startName),
        finishName: clampText(raw.finishName),
        // Loop route: start and finish are the same place (one combined marker).
        loop: Boolean(raw.loop),
        packId,
        createdAt: raw.createdAt || new Date().toISOString(),
        trackRef,
        stats,
        boundaries,
        dayNotes,
        extraDays,
        startDayNumber,
        checkpoints
      };
    })
    .filter(Boolean);
}

export function defaultData() {
  return {
    schemaVersion: SCHEMA_VERSION,
    trips: [],
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
        image: "",
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
export function normalizeData(parsed, tracks = null) {
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

  const trips = normalizeTrips(parsed.trips, validPackIds, tracks);

  return {
    schemaVersion: SCHEMA_VERSION,
    gears,
    packs: withPackDefaults.packs,
    packItems,
    trips
  };
}

// --- Bundle codec (doc + tracks) -----------------------------------------
//
// A "bundle" is the pair the app persists/syncs: the light document plus the
// heavy tracks map. buildPortableBundle() flattens them into one object for
// export/Drive; applyPortableBundle() is the single normalize gate for every
// untrusted ingress (profile import, Drive pull).

export function readTracks() {
  try {
    const raw = localStorage.getItem(TRACKS_KEY);
    return raw ? sanitizeTracks(JSON.parse(raw)) : {};
  } catch {
    return {};
  }
}

// Read the local bundle, migrating v3 → v4 once (v3 is left in place). Returns
// { doc, tracks } where doc is normalized app data incl. updatedAt.
export function readLocalBundle() {
  const tracks = readTracks();
  let rawDoc = null;
  let migrated = false;
  try {
    const v4 = localStorage.getItem(STORAGE_KEY);
    if (v4) {
      rawDoc = JSON.parse(v4);
    } else {
      const v3 = localStorage.getItem(LEGACY_STORAGE_KEY_V3);
      if (v3) {
        rawDoc = JSON.parse(v3);
        migrated = true; // backfill happens via normalizeData/defaults
      }
    }
  } catch {
    rawDoc = null;
  }
  if (!rawDoc) {
    const doc = defaultData();
    return { doc: { ...doc, updatedAt: "" }, tracks: {}, migrated: false };
  }
  const norm = normalizeData(rawDoc, tracks) || defaultData();
  // Migration must NOT bump updatedAt (carry v3's value, incl. "").
  return { doc: { ...norm, updatedAt: rawDoc.updatedAt || "" }, tracks, migrated };
}

// Prune track assets no longer referenced by any trip (orphan GC).
export function gcTracks(trips, tracks) {
  const referenced = new Set(
    (trips || []).map((t) => t.trackRef?.id).filter(Boolean)
  );
  const out = {};
  for (const [key, value] of Object.entries(tracks || {})) {
    if (referenced.has(key)) out[key] = value;
  }
  return out;
}

// Flatten doc + tracks into one portable object (export / Drive push).
export function buildPortableBundle(doc, tracks) {
  return { ...doc, schemaVersion: SCHEMA_VERSION, tracks: tracks || {} };
}

// Normalize an untrusted flattened bundle back into { doc, tracks }. Order:
// sanitize doc → sanitize tracks → resolve trackRefs + recompute stats +
// re-clamp checkpoints (all inside normalizeData) → GC orphans.
export function applyPortableBundle(raw) {
  if (!raw || typeof raw !== "object") return null;
  const tracks = sanitizeTracks(raw.tracks);
  const norm = normalizeData(raw, tracks);
  if (!norm) return null;
  const doc = { ...norm, updatedAt: raw.updatedAt || new Date().toISOString() };
  return { doc, tracks: gcTracks(doc.trips, tracks) };
}

export function readStorage() {
  return readLocalBundle().doc;
}
