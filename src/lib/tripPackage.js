// TripPackage v1 — the contract between the web planner and the iOS companion.
//
// The web app owns trips; the companion only ever reads them, navigates, and
// records an activity alongside. So this is deliberately NOT the app's internal
// trip shape: it carries what navigation needs (route geometry, checkpoints,
// itinerary, thresholds) and drops what it doesn't (gear, packs, cover images,
// editor-only state). Anything added here has to be implemented twice — once in
// JS, once in Swift — so the bar for adding a field is high.
//
// A package is immutable for a given `tripId + revision`. `contentHash` is the
// content identity: it covers everything except `publishedAt` and the hash
// field itself, so re-exporting an unchanged trip yields the same hash.

import { buildCumulatives, buildDays, buildTrackStats } from "./trail.js";

export const TRIP_PACKAGE_FORMAT = "ulpacker-trip-package";
export const TRIP_PACKAGE_VERSION = 1;

// Not a security hash — this detects "did the content change", nothing more.
// FNV-1a was picked over SHA-256 because it stays synchronous (no WebCrypto
// promise in an export handler) and is ~15 lines in Swift as well as here.
// The algorithm is named in the payload so it can be swapped without ambiguity.
export const HASH_ALGORITHM = "fnv1a64";

// Off-route defaults. 75 m is a provisional value to be field-calibrated (see
// MOBILE_PLAN §3.2): a static 200 m threshold only fires ~3 minutes after the
// walker left the route. Exit sits below enter so the state machine has
// hysteresis instead of oscillating on GPS noise.
export const DEFAULT_OFF_ROUTE_ENTER_M = 75;
export const DEFAULT_OFF_ROUTE_EXIT_M = 40;

// Matches COORD_DECIMALS in trail.js (~1.1 m). Coordinates are rounded before
// hashing so the hash can't depend on float noise from a re-import.
const COORD_DP = 5;
// Number of decimals used when a non-integer is serialised for hashing. Both
// languages must format identically, so the rule is fixed, not "shortest form".
const HASH_DP = 6;

function roundTo(value, dp) {
  const f = 10 ** dp;
  return Math.round(Number(value) * f) / f;
}

// --- Canonical serialisation (must be reimplemented identically in Swift) ---
//
// Object keys sorted; numbers emitted by an explicit rule (integers as digits,
// everything else at fixed HASH_DP decimals) because JS and Swift disagree on
// the "shortest round-trip" representation of a float. Undefined and null
// members are dropped so an absent field and an explicitly-null one hash alike.

function canonicalNumber(n) {
  if (!Number.isFinite(n)) throw new TypeError("Cannot canonicalise a non-finite number");
  return Number.isInteger(n) ? String(n) : n.toFixed(HASH_DP);
}

export function canonicalJson(value) {
  if (value === null || value === undefined) return "null";
  if (typeof value === "number") return canonicalNumber(value);
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const parts = [];
    for (const key of Object.keys(value).sort()) {
      const v = value[key];
      if (v === undefined || v === null) continue;
      parts.push(`${JSON.stringify(key)}:${canonicalJson(v)}`);
    }
    return `{${parts.join(",")}}`;
  }
  throw new TypeError(`Cannot canonicalise ${typeof value}`);
}

// 64-bit FNV-1a over the UTF-8 bytes, as 16 lowercase hex digits.
export function fnv1a64(text) {
  const MASK = 0xffffffffffffffffn;
  const PRIME = 0x100000001b3n;
  let hash = 0xcbf29ce484222325n;
  for (const byte of new TextEncoder().encode(text)) {
    hash = ((hash ^ BigInt(byte)) * PRIME) & MASK;
  }
  return hash.toString(16).padStart(16, "0");
}

// The hash covers the package minus the two fields that must not affect
// identity: the hash itself, and the timestamp of this particular export.
export function computeContentHash(pkg) {
  const { contentHash, publishedAt, ...rest } = pkg;
  return fnv1a64(canonicalJson(rest));
}

// --- Build -----------------------------------------------------------------

function packageSegments(segments) {
  const out = [];
  for (const seg of segments || []) {
    const points = [];
    for (const p of seg?.points || []) {
      if (!Array.isArray(p)) continue;
      const lat = Number(p[0]);
      const lng = Number(p[1]);
      if (!Number.isFinite(lat) || !Number.isFinite(lng)) continue;
      const ele = Number.isFinite(Number(p[2])) ? Math.round(Number(p[2])) : null;
      points.push(ele == null ? [roundTo(lat, COORD_DP), roundTo(lng, COORD_DP)] : [roundTo(lat, COORD_DP), roundTo(lng, COORD_DP), ele]);
    }
    if (points.length >= 2) out.push({ points });
  }
  return out;
}

// Checkpoints keep only what navigation reads. The internal anchor
// (segmentIndex/alongSegmentM/offsetM/source*) is dropped: routeDistanceM plus
// the coordinates are enough, and re-deriving the rest is the companion's job.
//
// Sorted by route distance here rather than trusting the caller: the app keeps
// trip.checkpoints ordered via normalizeTrips(), but the companion reads these
// as a sequence ("next checkpoint"), so the ordering has to be a property of
// the contract instead of an invariant maintained on the other side of it.
function packageCheckpoints(checkpoints) {
  return (checkpoints || [])
    .map((cp) => {
      const a = cp?.anchor;
      if (!a || !Number.isFinite(a.lat) || !Number.isFinite(a.lng)) return null;
      return {
        id: cp.id,
        name: cp.name || "",
        note: cp.note || "",
        kind: cp.kind || "poi",
        routeDistanceM: Math.round(Number(a.routeDistanceM) || 0),
        lat: roundTo(a.lat, COORD_DP),
        lng: roundTo(a.lng, COORD_DP),
        ele: Number.isFinite(a.ele) ? Math.round(a.ele) : null
      };
    })
    .filter(Boolean)
    .sort((x, y) => x.routeDistanceM - y.routeDistanceM);
}

// buildDays() returns `{ days, warnings }` normally but a bare `[]` when the
// track is empty (an inconsistency in trail.js we work around rather than
// change, since the web UI depends on the current behaviour).
function packageItinerary(trip, segments) {
  if (!segments.length) return [];
  const cumulatives = buildCumulatives(segments);
  const built = buildDays({ checkpoints: trip.checkpoints || [], segments, cumulatives });
  const days = Array.isArray(built) ? [] : built.days || [];
  const notes = trip.dayNotes && typeof trip.dayNotes === "object" ? trip.dayNotes : {};
  return days.map((day) => ({
    index: day.index,
    startRouteM: Math.round(day.startRouteM),
    endRouteM: Math.round(day.endRouteM),
    distanceM: Math.round(day.distanceM),
    startBoundary: day.startBoundary,
    startName: day.startName || "",
    endBoundary: day.endBoundary,
    endName: day.endName || "",
    ascentM: day.ascentM == null ? null : Math.round(day.ascentM),
    descentM: day.descentM == null ? null : Math.round(day.descentM),
    note: typeof notes[day.startBoundary] === "string" ? notes[day.startBoundary] : ""
  }));
}

// Off-track itinerary days (travel, rest, shuttle). They carry no geometry, so
// the companion shows them in the day list but never navigates them.
function packageExtraDays(extraDays) {
  return (extraDays || [])
    .filter((d) => d && typeof d === "object")
    .map((d) => ({
      id: d.id,
      before: d.before || "finish",
      title: d.title || "",
      note: typeof d.note === "string" ? d.note : ""
    }));
}

/**
 * Build a TripPackage v1 from the app's internal trip + track.
 *
 * Returns null when the trip has no usable route — a package without geometry
 * is useless to a navigator, so callers should surface that to the user rather
 * than shipping an empty package.
 *
 * `revision` is caller-supplied and defaults to 1: trips do not yet persist a
 * revision (adding one means widening the trip schema in storage.js, which is
 * deliberately out of scope for the contract freeze). `contentHash` already
 * answers "is this different"; `revision` answers "is this newer", and wiring
 * it to persistent state is a follow-up.
 */
export function buildTripPackage(trip, track, options = {}) {
  if (!trip || typeof trip !== "object") return null;
  const segments = packageSegments(track?.segments);
  if (!segments.length) return null;

  const revision = Number.isFinite(Number(options.revision)) ? Math.max(1, Math.trunc(Number(options.revision))) : 1;
  const publishedAt = options.publishedAt || new Date().toISOString();
  const stats = buildTrackStats(segments);

  const pkg = {
    format: TRIP_PACKAGE_FORMAT,
    schemaVersion: TRIP_PACKAGE_VERSION,
    hashAlgorithm: HASH_ALGORITHM,
    tripId: trip.id,
    revision,
    publishedAt,
    trip: {
      name: trip.name || "Untitled trip",
      description: trip.description || "",
      startName: trip.startName || "",
      finishName: trip.finishName || "",
      loop: Boolean(trip.loop),
      startDayNumber: trip.startDayNumber === 0 ? 0 : 1
    },
    plannedRoute: {
      segments,
      stats: {
        distanceM: Math.round(stats.distanceM),
        ascentM: stats.ascentM == null ? null : Math.round(stats.ascentM),
        descentM: stats.descentM == null ? null : Math.round(stats.descentM),
        minEle: stats.minEle == null ? null : Math.round(stats.minEle),
        maxEle: stats.maxEle == null ? null : Math.round(stats.maxEle),
        elevationCoverage: roundTo(stats.elevationCoverage, 3),
        pointCount: segments.reduce((n, s) => n + s.points.length, 0),
        segmentCount: segments.length
      }
    },
    checkpoints: packageCheckpoints(trip.checkpoints),
    itinerary: packageItinerary(trip, segments),
    extraDays: packageExtraDays(trip.extraDays),
    navigationDefaults: {
      offRouteEnterM: Number.isFinite(Number(options.offRouteEnterM))
        ? Math.max(1, Math.round(Number(options.offRouteEnterM)))
        : DEFAULT_OFF_ROUTE_ENTER_M,
      offRouteExitM: Number.isFinite(Number(options.offRouteExitM))
        ? Math.max(1, Math.round(Number(options.offRouteExitM)))
        : DEFAULT_OFF_ROUTE_EXIT_M
    }
  };

  pkg.contentHash = computeContentHash(pkg);
  return pkg;
}

// --- Validate --------------------------------------------------------------

/**
 * Validate an untrusted TripPackage (a file the companion or a user hands us).
 * Returns { ok, errors } — errors is empty when ok. Structural problems and a
 * mismatched hash are both failures; an unknown newer schemaVersion is also a
 * failure here, because this validator only knows v1.
 */
export function validateTripPackage(raw) {
  const errors = [];
  const fail = (msg) => {
    errors.push(msg);
    return { ok: false, errors };
  };

  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return fail("Not an object.");
  if (raw.format !== TRIP_PACKAGE_FORMAT) return fail(`Wrong format (expected "${TRIP_PACKAGE_FORMAT}").`);
  if (raw.schemaVersion !== TRIP_PACKAGE_VERSION) {
    return fail(`Unsupported schemaVersion ${raw.schemaVersion} (this build reads ${TRIP_PACKAGE_VERSION}).`);
  }
  if (raw.hashAlgorithm !== HASH_ALGORITHM) return fail(`Unsupported hashAlgorithm "${raw.hashAlgorithm}".`);
  if (typeof raw.tripId !== "string" || !raw.tripId) errors.push("Missing tripId.");
  if (!Number.isInteger(raw.revision) || raw.revision < 1) errors.push("revision must be a positive integer.");
  if (typeof raw.publishedAt !== "string" || Number.isNaN(Date.parse(raw.publishedAt))) {
    errors.push("publishedAt must be an ISO timestamp.");
  }
  if (!raw.trip || typeof raw.trip !== "object") errors.push("Missing trip.");

  const segments = raw.plannedRoute?.segments;
  if (!Array.isArray(segments) || segments.length === 0) {
    errors.push("plannedRoute.segments must be a non-empty array.");
  } else {
    let bad = 0;
    for (const seg of segments) {
      if (!Array.isArray(seg?.points) || seg.points.length < 2) {
        bad += 1;
        continue;
      }
      for (const p of seg.points) {
        const lat = Number(p?.[0]);
        const lng = Number(p?.[1]);
        if (!Number.isFinite(lat) || lat < -90 || lat > 90 || !Number.isFinite(lng) || lng < -180 || lng > 180) {
          bad += 1;
          break;
        }
      }
    }
    if (bad) errors.push(`${bad} segment(s) are empty or contain out-of-range coordinates.`);
  }

  if (!Array.isArray(raw.checkpoints)) errors.push("checkpoints must be an array.");
  if (!Array.isArray(raw.itinerary)) errors.push("itinerary must be an array.");

  if (typeof raw.contentHash !== "string" || !raw.contentHash) {
    errors.push("Missing contentHash.");
  } else if (errors.length === 0) {
    // Only worth checking once the shape is sound; a hash mismatch on a
    // malformed package tells the user nothing useful.
    let actual;
    try {
      actual = computeContentHash(raw);
    } catch (e) {
      errors.push(`Could not hash the package: ${e.message}`);
    }
    if (actual && actual !== raw.contentHash) {
      errors.push(`contentHash mismatch (file says ${raw.contentHash}, content hashes to ${actual}).`);
    }
  }

  return { ok: errors.length === 0, errors };
}
