// Pure geo/GPX library for the Trips feature. No DOM/React state beyond
// DOMParser (parseGpx only), so every function here is unit-testable in
// isolation. A future map layer can reuse the same geometry.

import { id } from "./util.js";

// --- Shared hard limits (applied to EVERY ingress: GPX, profile import, cloud pull) ---
// Starting values; revisit after benchmarking on desktop + iPhone.
export const MAX_GPX_BYTES = 15 * 1024 * 1024;
export const MAX_TRACK_POINTS = 50_000;
export const MAX_SEGMENTS = 50;
export const MAX_TRIPS = 20;
export const MAX_CHECKPOINTS_PER_TRIP = 100;
export const MAX_TEXT_LENGTH = 500;
export const MAX_DAY_NOTE_LENGTH = 4000;
export const MAX_DAY_NOTES = 60;
export const MAX_TRACK_STORAGE_BYTES = 2 * 1024 * 1024;
export const MIN_STORAGE_HEADROOM = 256 * 1024;
export const OFF_ROUTE_M = 200;

// Bumping this recomputes cached trip stats on load.
export const METRICS_VERSION = 1;

// Categorical palette used to colour each day's stretch of trail (map, profile
// and the itinerary card border). Validated for adjacent-pair separation:
// worst adjacent CVD ΔE 9.1, normal-vision ΔE 19.6 — which is what matters here,
// since consecutive days are the ones that touch. Days beyond the eighth reuse
// the order; repeats land far apart on the route and every day is labelled.
export const DAY_COLORS = [
  "#2a78d6", // blue
  "#eb6834", // orange
  "#1baf7a", // aqua
  "#eda100", // yellow
  "#e87ba4", // magenta
  "#008300", // green
  "#4a3aa7", // violet
  "#e34948" // red
];
// Off-route days are never on the track; one fixed neutral, clearly not a hue.
export const OFF_ROUTE_COLOR = "#64748b";

export function dayColor(i) {
  return DAY_COLORS[((i % DAY_COLORS.length) + DAY_COLORS.length) % DAY_COLORS.length];
}

// Pick black or white text for a solid background by WCAG contrast (computed,
// not eyeballed) — so a "Day N" badge stays readable on any hue.
function relLuminance(hex) {
  const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const lin = c.map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
  return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}
const DARK_INK = "#1c1c22";
const DARK_INK_LUM = relLuminance(DARK_INK);
export function readableOn(hex) {
  if (typeof hex !== "string" || !/^#[0-9a-fA-F]{6}$/.test(hex)) return "#ffffff";
  const bg = relLuminance(hex);
  const ratio = (a, b) => (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  // Compare against the ACTUAL inks used (white vs #1c1c22), not pure black.
  return ratio(1, bg) >= ratio(DARK_INK_LUM, bg) ? "#ffffff" : DARK_INK;
}

// Checkpoint categories. "overnight" is special — it drives the day itinerary.
// The rest are informational markers shown on the map/profile.
export const CHECKPOINT_KINDS = {
  overnight: { label: "Overnight", emoji: "⛺" },
  refuge: { label: "Refuge / hotel", emoji: "🏨" },
  food: { label: "Food", emoji: "🍴" },
  water: { label: "Water", emoji: "💧" },
  resupply: { label: "Resupply", emoji: "🛒" },
  transport: { label: "Transport", emoji: "🚆" },
  pass: { label: "Pass / summit", emoji: "⛰️" },
  viewpoint: { label: "Viewpoint", emoji: "📷" },
  hazard: { label: "Hazard", emoji: "⚠️" },
  poi: { label: "Landmark", emoji: "📍" }
};
export const CHECKPOINT_KIND_KEYS = Object.keys(CHECKPOINT_KINDS);

export function isCheckpointKind(k) {
  return Object.prototype.hasOwnProperty.call(CHECKPOINT_KINDS, k);
}

export function isOvernight(cp) {
  return cp?.kind === "overnight";
}

// Guess a checkpoint category from its name using hiking vocabulary. Order
// matters: the most specific/hazardous signals win. Falls back to "poi".
export function classifyCheckpoint(name) {
  const s = (name || "").toLowerCase();
  if (/hazard|ladder|footbridge|exposed|chain|danger|scree|\bford\b|crevasse|snowfield|rockfall|via ?ferrata/.test(s)) return "hazard";
  if (/transport|shuttle|\bbus\b|train|station|\bgare\b|cable ?car|t[eé]l[eé]ph[eé]rique|funicular|gondola|chairlift|\blift\b|ferry|taxi|parking/.test(s)) return "transport";
  if (/resupply|supermarket|grocery|\bshop\b|\bstore\b|market|provision|\bgas\b|\bfuel\b/.test(s)) return "resupply";
  if (/lunch|restaurant|\bfood\b|dining|caf[eé]|\bbar\b|snack|picnic|\beat\b|\bmeal\b|breakfast|dinner|buvette/.test(s)) return "food";
  if (/water|refill|fountain|spring|\bsource\b|potable|\beau\b/.test(s)) return "water";
  if (/viewpoint|panorama|balcony|belv[eé]d|overlook|vista|belvedere/.test(s)) return "viewpoint";
  if (/\bcol\b|\bpass\b|summit|weather gate|\bpeak\b|t[eê]te|aiguillette|\bcime\b/.test(s)) return "pass";
  if (/refuge|rifugio|auberge|g[iî]te|hostel|hotel|\bhut\b|hospice|berghaus|lodge|\binn\b/.test(s)) return "refuge";
  if (/camping|bivouac|bivacco|dortoir|\bcamp\b|\bdorm\b|\btent\b/.test(s)) return "overnight";
  return "poi";
}

const EARTH_R = 6371000; // metres
const DEG2RAD = Math.PI / 180;
const COORD_DECIMALS = 5; // ~1.1 m

function round(value, decimals) {
  const f = 10 ** decimals;
  return Math.round(value * f) / f;
}

export function clampText(value, max = MAX_TEXT_LENGTH) {
  return typeof value === "string" ? value.slice(0, max) : "";
}

// Great-circle distance between two [lat, lng] points, in metres.
export function haversine(aLat, aLng, bLat, bLng) {
  const dLat = (bLat - aLat) * DEG2RAD;
  const dLng = (bLng - aLng) * DEG2RAD;
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(aLat * DEG2RAD) * Math.cos(bLat * DEG2RAD) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_R * Math.asin(Math.min(1, Math.sqrt(s)));
}

function validLat(v) {
  return Number.isFinite(v) && v >= -90 && v <= 90;
}
function validLng(v) {
  return Number.isFinite(v) && v >= -180 && v <= 180;
}

// Round a raw [lat, lng, ele] triple; drop the point (return null) when the
// coordinate is out of range. ele stays null when missing/invalid.
function normalizePoint(lat, lng, ele) {
  if (!validLat(lat) || !validLng(lng)) return null;
  const e = Number.isFinite(ele) ? Math.round(ele) : null;
  return [round(lat, COORD_DECIMALS), round(lng, COORD_DECIMALS), e];
}

// ---------------------------------------------------------------------------
// GPX parsing
// ---------------------------------------------------------------------------

// Returns { candidates: [{ id, kind, name, segments }], waypoints, warnings }.
// Each <trk> is one candidate (keeping all its <trkseg>); each <rte> is a
// one-segment candidate. The PARSER never merges — merging is a downstream
// choice: the import UI may concatenate several candidates' segments in file
// order (safe, because segment boundaries are never counted as distance).
// Waypoints are file-level suggestions, snapped to the chosen track at confirm.
export function parseGpx(xmlText, limits = {}) {
  const maxBytes = limits.maxBytes ?? MAX_GPX_BYTES;
  const maxPoints = limits.maxPoints ?? MAX_TRACK_POINTS;
  const maxSegments = limits.maxSegments ?? MAX_SEGMENTS;
  const warnings = [];

  if (typeof xmlText !== "string" || xmlText.trim() === "") {
    throw new Error("Empty or invalid GPX file.");
  }
  // Byte guard (the caller also checks File.size, this covers pasted text).
  if (xmlText.length > maxBytes) {
    throw new Error("GPX file is too large.");
  }
  // Refuse DTDs / entity declarations before handing anything to the parser
  // (XXE / billion-laughs surface).
  if (/<!DOCTYPE/i.test(xmlText) || /<!ENTITY/i.test(xmlText)) {
    throw new Error("GPX file contains a document type declaration.");
  }

  const doc = new DOMParser().parseFromString(xmlText, "text/xml");
  if (doc.getElementsByTagName("parsererror").length > 0) {
    throw new Error("GPX file is not valid XML.");
  }

  const byLocal = (root, name) =>
    Array.from(root.getElementsByTagName("*")).filter((el) => el.localName === name);
  const directChildren = (root, name) =>
    Array.from(root.children).filter((el) => el.localName === name);

  let pointBudget = maxPoints;
  const candidates = [];

  const readPoints = (nodes) => {
    const points = [];
    for (const node of nodes) {
      if (pointBudget <= 0) {
        throw new Error(`GPX track exceeds ${maxPoints} points.`);
      }
      const lat = Number(node.getAttribute("lat"));
      const lng = Number(node.getAttribute("lon"));
      const eleNode = directChildren(node, "ele")[0];
      const ele = eleNode ? Number(eleNode.textContent) : NaN;
      const p = normalizePoint(lat, lng, ele);
      if (p) {
        points.push(p);
        pointBudget -= 1;
      }
    }
    return points;
  };

  const pushCandidate = (kind, name, segments) => {
    const cleaned = segments.filter((seg) => seg.points.length >= 2);
    const total = cleaned.reduce((n, seg) => n + seg.points.length, 0);
    if (cleaned.length === 0 || total < 2) {
      warnings.push(`Skipped "${name || kind}" — fewer than 2 valid points.`);
      return;
    }
    if (cleaned.length > maxSegments) {
      cleaned.length = maxSegments;
      warnings.push(`"${name || kind}" had more than ${maxSegments} segments; extra dropped.`);
    }
    const trimmed = clampText(name);
    // `named` marks a real <name> from the file (vs. our positional fallback),
    // so the UI can decide whether track names are meaningful stage labels.
    candidates.push({
      id: id(),
      kind,
      named: Boolean(trimmed),
      name: trimmed || `${kind} ${candidates.length + 1}`,
      segments: cleaned
    });
  };

  // Tracks: one candidate per <trk>, one segment per <trkseg>.
  for (const trk of byLocal(doc, "trk")) {
    const nameNode = directChildren(trk, "name")[0];
    const segs = byLocal(trk, "trkseg").map((seg) => ({ points: readPoints(byLocal(seg, "trkpt")) }));
    pushCandidate("track", nameNode?.textContent?.trim(), segs);
  }

  // Routes: one candidate per <rte>, a single segment of <rtept>.
  for (const rte of byLocal(doc, "rte")) {
    const nameNode = directChildren(rte, "name")[0];
    const pts = readPoints(byLocal(rte, "rtept"));
    pushCandidate("route", nameNode?.textContent?.trim(), [{ points: pts }]);
  }

  // Waypoints (file level).
  const waypoints = [];
  for (const wpt of byLocal(doc, "wpt")) {
    const lat = Number(wpt.getAttribute("lat"));
    const lng = Number(wpt.getAttribute("lon"));
    if (!validLat(lat) || !validLng(lng)) continue;
    const nameNode = directChildren(wpt, "name")[0];
    waypoints.push({
      name: clampText(nameNode?.textContent?.trim()) || `Waypoint ${waypoints.length + 1}`,
      lat: round(lat, COORD_DECIMALS),
      lng: round(lng, COORD_DECIMALS)
    });
  }

  if (candidates.length === 0) {
    warnings.push("No usable track or route found in this file.");
  }

  return { candidates, waypoints, warnings };
}

// ---------------------------------------------------------------------------
// Per-segment cumulative distance + offsets
// ---------------------------------------------------------------------------

// Cumulative distance array for a single segment (cumulative[0] === 0).
export function segmentCumulative(points) {
  const cum = [0];
  for (let i = 1; i < points.length; i += 1) {
    const [aLat, aLng] = points[i - 1];
    const [bLat, bLng] = points[i];
    cum.push(cum[i - 1] + haversine(aLat, aLng, bLat, bLng));
  }
  return cum;
}

// Returns { cumulativeBySegment, segmentOffsets, segmentLengths, totalM }.
// Offsets are contiguous (segment N starts where N-1 ended) so a gap between
// physical segments contributes ZERO distance — routeDistanceM never counts it.
export function buildCumulatives(segments) {
  const cumulativeBySegment = [];
  const segmentLengths = [];
  const segmentOffsets = [];
  let totalM = 0;
  for (const seg of segments) {
    const cum = segmentCumulative(seg.points);
    cumulativeBySegment.push(cum);
    segmentOffsets.push(totalM);
    const len = cum[cum.length - 1] || 0;
    segmentLengths.push(len);
    totalM += len;
  }
  return { cumulativeBySegment, segmentOffsets, segmentLengths, totalM };
}

// Fuse adjacent segments whose endpoints touch (end of one within thresholdM of
// the start of the next). Routes exported as many contiguous OSM ways come in as
// separate tracks/segments that are really one continuous line — joining them
// removes phantom "gap" markers. A real gap (endpoints far apart) is preserved.
export function joinContiguousSegments(segments, thresholdM = 30) {
  if (!Array.isArray(segments) || segments.length <= 1) return segments;
  const out = [];
  for (const seg of segments) {
    if (!seg?.points?.length) continue;
    if (out.length === 0) {
      out.push({ points: seg.points.slice() });
      continue;
    }
    const prev = out[out.length - 1];
    const a = prev.points[prev.points.length - 1];
    const b = seg.points[0];
    const d = haversine(a[0], a[1], b[0], b[1]);
    if (d <= thresholdM) {
      // Contiguous — append, dropping a duplicated shared node (< ~1 m).
      const startIdx = d < 1 ? 1 : 0;
      for (let i = startIdx; i < seg.points.length; i += 1) prev.points.push(seg.points[i]);
    } else {
      out.push({ points: seg.points.slice() });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Elevation-aware ascent/descent
// ---------------------------------------------------------------------------

// 5-point moving average over a run of finite elevations.
function smooth(eles) {
  const n = eles.length;
  const out = new Array(n);
  for (let i = 0; i < n; i += 1) {
    let sum = 0;
    let count = 0;
    for (let k = Math.max(0, i - 2); k <= Math.min(n - 1, i + 2); k += 1) {
      sum += eles[k];
      count += 1;
    }
    out[i] = sum / count;
  }
  return out;
}

// Accumulate ascent/descent over one contiguous run of finite elevations.
function runGainLoss(eles) {
  const s = smooth(eles);
  let asc = 0;
  let desc = 0;
  for (let i = 1; i < s.length; i += 1) {
    const d = s[i] - s[i - 1];
    if (d > 0) asc += d;
    else desc -= d;
  }
  return { asc, desc };
}

// Compute canonical stats from geometry. NEVER trust cached stats from a
// backup/cloud; recompute here at ingress. all-missing elevation → nulls, not
// 0/Infinity. Smoothing resets per segment AND at every missing-ele gap.
export function buildTrackStats(segments) {
  const { cumulativeBySegment, segmentOffsets, segmentLengths, totalM } = buildCumulatives(segments);

  let ascentM = 0;
  let descentM = 0;
  let minEle = Infinity;
  let maxEle = -Infinity;
  let elePoints = 0;
  let totalPoints = 0;
  let hasEle = false;

  for (const seg of segments) {
    let run = [];
    const flushRun = () => {
      if (run.length >= 2) {
        const { asc, desc } = runGainLoss(run);
        ascentM += asc;
        descentM += desc;
      }
      run = [];
    };
    for (const [, , ele] of seg.points) {
      totalPoints += 1;
      if (Number.isFinite(ele)) {
        hasEle = true;
        elePoints += 1;
        if (ele < minEle) minEle = ele;
        if (ele > maxEle) maxEle = ele;
        run.push(ele);
      } else {
        flushRun();
      }
    }
    flushRun();
  }

  return {
    distanceM: Math.round(totalM),
    ascentM: hasEle ? Math.round(ascentM) : null,
    descentM: hasEle ? Math.round(descentM) : null,
    minEle: hasEle ? minEle : null,
    maxEle: hasEle ? maxEle : null,
    elevationCoverage: totalPoints > 0 ? round(elePoints / totalPoints, 3) : 0,
    metricsVersion: METRICS_VERSION,
    // Non-persisted extras handy for callers/UI:
    cumulativeBySegment,
    segmentOffsets,
    segmentLengths,
    totalM
  };
}

// ---------------------------------------------------------------------------
// Snapping + anchors
// ---------------------------------------------------------------------------

// Project a point onto a single edge in a local planar frame anchored at
// refLat. Returns { t, dist (m from source), lat, lng, ele }.
function projectOntoEdge(a, b, lat, lng, refLat) {
  const mPerLat = 111320;
  const mPerLng = 111320 * Math.cos(refLat * DEG2RAD);
  const ax = a[1] * mPerLng;
  const ay = a[0] * mPerLat;
  const bx = b[1] * mPerLng;
  const by = b[0] * mPerLat;
  const px = lng * mPerLng;
  const py = lat * mPerLat;
  const dx = bx - ax;
  const dy = by - ay;
  const len2 = dx * dx + dy * dy;
  let t = len2 === 0 ? 0 : ((px - ax) * dx + (py - ay) * dy) / len2;
  t = Math.max(0, Math.min(1, t));
  const sx = ax + t * dx;
  const sy = ay + t * dy;
  const dist = Math.hypot(px - sx, py - sy);
  const snappedLat = a[0] + t * (b[0] - a[0]);
  const snappedLng = a[1] + t * (b[1] - a[1]);
  const ele =
    Number.isFinite(a[2]) && Number.isFinite(b[2]) ? a[2] + t * (b[2] - a[2]) : (a[2] ?? b[2] ?? null);
  return { t, dist, lat: snappedLat, lng: snappedLng, ele };
}

// Snap a source [lat,lng] onto the nearest track EDGE (not nearest vertex).
// Returns a full anchor (see plan §2.4). `prefer` (routeDistanceM) biases the
// tie-break toward a previous position on loops/self-intersections.
export function snapToTrack(segments, lat, lng, options = {}) {
  const { cumulativeBySegment, segmentOffsets } = options.cumulatives || buildCumulatives(segments);
  const prefer = options.preferRouteM;
  let best = null;
  let secondBestDist = Infinity;

  for (let s = 0; s < segments.length; s += 1) {
    const pts = segments[s].points;
    const cum = cumulativeBySegment[s];
    for (let i = 1; i < pts.length; i += 1) {
      const proj = projectOntoEdge(pts[i - 1], pts[i], lat, lng, lat);
      const alongSegmentM = cum[i - 1] + proj.t * (cum[i] - cum[i - 1]);
      const routeDistanceM = segmentOffsets[s] + alongSegmentM;
      const candidate = {
        segmentIndex: s,
        alongSegmentM,
        routeDistanceM,
        lat: round(proj.lat, COORD_DECIMALS),
        lng: round(proj.lng, COORD_DECIMALS),
        ele: Number.isFinite(proj.ele) ? Math.round(proj.ele) : null,
        offsetM: Math.round(proj.dist),
        _dist: proj.dist
      };
      if (!best) {
        best = candidate;
        continue;
      }
      // Tie-break on loops: comparable distance → prefer the one closer to the
      // previous routeDistanceM.
      const close = Math.min(candidate._dist, best._dist);
      const far = Math.max(candidate._dist, best._dist);
      const comparable = far <= 2 * (close + 1);
      if (candidate._dist < best._dist) {
        if (comparable && prefer != null &&
            Math.abs(best.routeDistanceM - prefer) < Math.abs(candidate.routeDistanceM - prefer)) {
          // Keep best (it is nearer the previous position); note ambiguity.
          secondBestDist = candidate._dist;
        } else {
          secondBestDist = best._dist;
          best = candidate;
        }
      } else if (candidate._dist < secondBestDist) {
        secondBestDist = candidate._dist;
      }
    }
  }

  if (!best) return null;
  const ambiguous = secondBestDist !== Infinity && secondBestDist <= 2 * (best._dist + 1);
  const { _dist, ...anchor } = best;
  return {
    ...anchor,
    sourceLat: round(lat, COORD_DECIMALS),
    sourceLng: round(lng, COORD_DECIMALS),
    ambiguous
  };
}

// Build a full anchor at a given route distance (e.g. a click on the elevation
// profile). Finds the containing segment, then the snapped point there.
export function anchorAtRouteM(segments, cumulatives, routeM) {
  const { cumulativeBySegment, segmentOffsets, segmentLengths, totalM } = cumulatives;
  const clamped = Math.max(0, Math.min(totalM, routeM));
  let s = 0;
  for (let i = 0; i < segments.length; i += 1) {
    if (clamped <= segmentOffsets[i] + segmentLengths[i] || i === segments.length - 1) {
      s = i;
      break;
    }
  }
  const alongSegmentM = Math.max(0, Math.min(segmentLengths[s], clamped - segmentOffsets[s]));
  const p = pointAtAnchor(segments, cumulativeBySegment, { segmentIndex: s, alongSegmentM });
  return {
    segmentIndex: s,
    alongSegmentM,
    routeDistanceM: segmentOffsets[s] + alongSegmentM,
    lat: p ? round(p.lat, COORD_DECIMALS) : 0,
    lng: p ? round(p.lng, COORD_DECIMALS) : 0,
    ele: p && Number.isFinite(p.ele) ? Math.round(p.ele) : null,
    offsetM: 0,
    sourceLat: p ? round(p.lat, COORD_DECIMALS) : 0,
    sourceLng: p ? round(p.lng, COORD_DECIMALS) : 0
  };
}

// Resolve a stored anchor {segmentIndex, alongSegmentM} to a concrete point.
// Unambiguous even at a segment boundary (unlike a global routeDistance).
export function pointAtAnchor(segments, cumulativeBySegment, anchor) {
  const s = Math.max(0, Math.min(segments.length - 1, anchor.segmentIndex | 0));
  const pts = segments[s]?.points || [];
  const cum = cumulativeBySegment[s] || [0];
  if (pts.length === 0) return null;
  const target = Math.max(0, Math.min(cum[cum.length - 1], anchor.alongSegmentM));
  for (let i = 1; i < pts.length; i += 1) {
    if (cum[i] >= target) {
      const span = cum[i] - cum[i - 1] || 1;
      const t = (target - cum[i - 1]) / span;
      const a = pts[i - 1];
      const b = pts[i];
      return {
        lat: a[0] + t * (b[0] - a[0]),
        lng: a[1] + t * (b[1] - a[1]),
        ele: Number.isFinite(a[2]) && Number.isFinite(b[2]) ? a[2] + t * (b[2] - a[2]) : null,
        segmentIndex: s
      };
    }
  }
  const last = pts[pts.length - 1];
  return { lat: last[0], lng: last[1], ele: last[2], segmentIndex: s };
}

// ---------------------------------------------------------------------------
// Render helpers (pure geometry; components turn these into SVG)
// ---------------------------------------------------------------------------

// Thin each segment for drawing only (stats always use full resolution).
// Keeps the first and last point of every segment.
export function decimateForRender(segments, maxN = 1500) {
  const total = segments.reduce((n, s) => n + s.points.length, 0);
  if (total <= maxN) return segments;
  const step = Math.ceil(total / maxN);
  return segments.map((seg) => {
    const pts = seg.points;
    if (pts.length <= 2) return { points: pts.slice() };
    const kept = [];
    for (let i = 0; i < pts.length; i += step) kept.push(pts[i]);
    if (kept[kept.length - 1] !== pts[pts.length - 1]) kept.push(pts[pts.length - 1]);
    return { points: kept };
  });
}

// Equirectangular projection to [x,y] within width×height, one path per
// segment. Returns { paths: [[[x,y],...]], viewBox }.
export function projectTrack(segments, width, height, pad = 4) {
  let minLat = Infinity, maxLat = -Infinity, minLng = Infinity, maxLng = -Infinity;
  for (const seg of segments)
    for (const [lat, lng] of seg.points) {
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }
  if (!Number.isFinite(minLat)) return { paths: [], width, height };
  const midLat = (minLat + maxLat) / 2;
  const kx = Math.cos(midLat * DEG2RAD);
  const spanX = Math.max((maxLng - minLng) * kx, 1e-9);
  const spanY = Math.max(maxLat - minLat, 1e-9);
  const scale = Math.min((width - 2 * pad) / spanX, (height - 2 * pad) / spanY);
  const offX = (width - spanX * scale) / 2;
  const offY = (height - spanY * scale) / 2;
  const project = (lat, lng) => [
    offX + (lng - minLng) * kx * scale,
    // invert Y so north is up
    height - (offY + (lat - minLat) * scale)
  ];
  const unproject = (x, y) => [
    minLat + (height - y - offY) / scale,
    minLng + (x - offX) / (kx * scale)
  ];
  const paths = segments.map((seg) => seg.points.map(([lat, lng]) => project(lat, lng)));
  return { paths, width, height, project, unproject };
}

// Per-segment [routeDistanceM, ele] series for the elevation profile. Segment
// breaks are returned separately so the component draws a vertical marker
// (a gap has 0 horizontal distance, so a dashed line is invisible).
export function buildElevationSeries(segments, cumulativeBySegment, segmentOffsets) {
  const series = segments.map((seg, s) =>
    seg.points.map(([, , ele], i) => [segmentOffsets[s] + cumulativeBySegment[s][i], ele])
  );
  const breaks = [];
  for (let s = 1; s < segments.length; s += 1) breaks.push(segmentOffsets[s]);
  return { series, breaks };
}

// Longitude span > ~180° means the track likely crosses the antimeridian; V1
// warns and hides the 2D shape (the profile is unaffected).
export function detectAntimeridian(segments) {
  let minLng = Infinity, maxLng = -Infinity;
  for (const seg of segments)
    for (const [, lng] of seg.points) {
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }
  return Number.isFinite(minLng) && maxLng - minLng > 180;
}

// ---------------------------------------------------------------------------
// Itinerary
// ---------------------------------------------------------------------------

// Flat, ordered samples across the whole track: { routeM, ele, segmentIndex }.
function flatSamples(segments, cumulativeBySegment, segmentOffsets) {
  const out = [];
  for (let s = 0; s < segments.length; s += 1) {
    const cum = cumulativeBySegment[s];
    segments[s].points.forEach(([, , ele], i) => {
      out.push({ routeM: segmentOffsets[s] + cum[i], ele, segmentIndex: s });
    });
  }
  return out;
}

// ascent/descent/coverage/segmentBreaks for samples within [startM, endM].
function statsForRange(samples, startM, endM) {
  let asc = 0;
  let desc = 0;
  let elePoints = 0;
  let total = 0;
  let breaks = 0;
  let run = [];
  let lastSeg = null;

  const flush = () => {
    if (run.length >= 2) {
      const { asc: a, desc: d } = runGainLoss(run);
      asc += a;
      desc += d;
    }
    run = [];
  };

  for (const sample of samples) {
    if (sample.routeM < startM - 1e-6 || sample.routeM > endM + 1e-6) continue;
    if (lastSeg != null && sample.segmentIndex !== lastSeg) {
      breaks += 1;
      flush();
    }
    lastSeg = sample.segmentIndex;
    total += 1;
    if (Number.isFinite(sample.ele)) {
      elePoints += 1;
      run.push(sample.ele);
    } else {
      flush();
    }
  }
  flush();
  return {
    ascentM: elePoints > 0 ? Math.round(asc) : null,
    descentM: elePoints > 0 ? Math.round(desc) : null,
    elevationCoverage: total > 0 ? round(elePoints / total, 3) : 0,
    segmentBreaks: breaks
  };
}

// Evenly-spaced interior route distances for a day split. Pass either a day
// count (N → N-1 splits) or a target spacing in km. Returns [] when nothing fits.
export function evenSplitRouteM(totalM, { days, everyKm } = {}) {
  if (!Number.isFinite(totalM) || totalM <= 0) return [];
  const out = [];
  if (Number.isFinite(days) && days >= 2) {
    for (let i = 1; i < Math.floor(days); i += 1) out.push(Math.round((totalM * i) / days));
  } else if (Number.isFinite(everyKm) && everyKm > 0) {
    for (let d = everyKm * 1000; d < totalM - 1; d += everyKm * 1000) out.push(Math.round(d));
  }
  return out.filter((r) => r > 1 && r < totalM - 1);
}

// True 1-D topographic prominence of a peak at index i: its height above the
// highest saddle that separates it from any higher ground (or the lowest point
// reached on a side if there is no higher ground that way).
function peakProminence(eles, i) {
  const h = eles[i];
  let left = Infinity;
  for (let k = i - 1; k >= 0; k -= 1) {
    if (eles[k] > h) break;
    if (eles[k] < left) left = eles[k];
  }
  let right = Infinity;
  for (let k = i + 1; k < eles.length; k += 1) {
    if (eles[k] > h) break;
    if (eles[k] < right) right = eles[k];
  }
  if (left === Infinity) left = -Infinity; // peak sits at the start
  if (right === Infinity) right = -Infinity; // …or the end
  return h - Math.max(left, right);
}

// Interior route distances of segment boundaries (each segment start/end is a
// natural "potential checkpoint"). Computed from the pre-fusion segments.
export function segmentBoundaryRouteMs(segments) {
  const { segmentOffsets, totalM } = buildCumulatives(segments);
  return segmentOffsets.slice(1).filter((r) => r > 1 && r < totalM - 1);
}

// Plan day-split positions, snapping each evenly-spaced target to the best
// nearby anchor by priority: overnight checkpoint > other checkpoint > segment
// boundary > the even position itself. Returns [{ routeM, source, id? }].
export function suggestDaySplits(totalM, target, { checkpoints = [], boundaries = [] } = {}) {
  const ideal = evenSplitRouteM(totalM, target);
  if (ideal.length === 0) return [];
  const span = target.days ? totalM / target.days : (target.everyKm || 1) * 1000;
  const tol = span * 0.45; // snap window: up to ~45% of a day toward a real anchor
  const anchors = [
    ...checkpoints
      .filter((cp) => Number.isFinite(cp?.anchor?.routeDistanceM))
      .map((cp) => ({ routeM: cp.anchor.routeDistanceM, source: "checkpoint", id: cp.id, priority: cp.kind === "overnight" ? 0 : 1 })),
    ...boundaries
      .filter((r) => Number.isFinite(r))
      .map((routeM) => ({ routeM, source: "boundary", priority: 2 }))
  ];
  const used = new Set();
  return ideal.map((pos) => {
    let best = null;
    for (const a of anchors) {
      const key = a.id || `b${Math.round(a.routeM)}`;
      if (used.has(key)) continue;
      const d = Math.abs(a.routeM - pos);
      if (d > tol) continue;
      if (!best || a.priority < best.priority || (a.priority === best.priority && d < best.d)) {
        best = { ...a, d, key };
      }
    }
    if (best) {
      used.add(best.key);
      return { routeM: best.routeM, source: best.source, id: best.id };
    }
    return { routeM: pos, source: "even" };
  });
}

// Extract the portion of the track between two route distances, as drawable
// segments. Used to highlight a single day's stretch on the map / shape.
export function sliceSegments(segments, cumulatives, fromM, toM) {
  const { cumulativeBySegment, segmentOffsets, segmentLengths } = cumulatives;
  const out = [];
  if (!(toM > fromM)) return out;
  for (let s = 0; s < segments.length; s += 1) {
    const segStart = segmentOffsets[s];
    const segEnd = segStart + segmentLengths[s];
    if (segEnd <= fromM || segStart >= toM) continue;
    const pts = segments[s].points;
    const cum = cumulativeBySegment[s];
    const localFrom = Math.max(0, fromM - segStart);
    const localTo = Math.min(segmentLengths[s], toM - segStart);

    const at = (target) => {
      for (let i = 1; i < pts.length; i += 1) {
        if (cum[i] >= target) {
          const span = cum[i] - cum[i - 1] || 1;
          const t = (target - cum[i - 1]) / span;
          const a = pts[i - 1];
          const b = pts[i];
          return [a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), a[2]];
        }
      }
      return pts[pts.length - 1];
    };

    const piece = [at(localFrom)];
    for (let i = 0; i < pts.length; i += 1) {
      if (cum[i] > localFrom && cum[i] < localTo) piece.push(pts[i]);
    }
    piece.push(at(localTo));
    if (piece.length >= 2) out.push({ points: piece });
  }
  return out;
}

// Detect topographic high/low points along the trail by 1-D prominence. Needs
// elevation. Returns the most prominent first: [{ routeM, ele, kind }].
export function detectExtrema(segments, cumulatives, { minProminenceM = 120, max = 12 } = {}) {
  const { cumulativeBySegment, segmentOffsets } = cumulatives;
  const pts = [];
  segments.forEach((seg, s) => {
    seg.points.forEach(([, , ele], i) => {
      if (Number.isFinite(ele)) pts.push([segmentOffsets[s] + cumulativeBySegment[s][i], ele]);
    });
  });
  if (pts.length < 3) return [];

  const eles = smooth(pts.map((p) => p[1]));
  const inv = eles.map((e) => -e); // for low points, prominence of the inverted profile

  // Turning points (slope sign flips), collapsing flats.
  const extrema = [];
  let dir = 0;
  for (let i = 1; i < eles.length; i += 1) {
    const d = eles[i] - eles[i - 1];
    if (d === 0) continue;
    const s = d > 0 ? 1 : -1;
    if (dir !== 0 && s !== dir) extrema.push({ i: i - 1, kind: dir > 0 ? "high" : "low" });
    dir = s;
  }
  if (extrema.length === 0) return [];

  const scored = extrema.map((e) => ({
    routeM: Math.round(pts[e.i][0]),
    ele: Math.round(pts[e.i][1]),
    kind: e.kind,
    prom: e.kind === "high" ? peakProminence(eles, e.i) : peakProminence(inv, e.i)
  }));

  return scored
    .filter((e) => e.prom >= minProminenceM)
    .sort((a, b) => b.prom - a.prom)
    .slice(0, max)
    .map(({ prom, ...rest }) => rest);
}

// Derive day segments from overnight checkpoints. Virtual Start/Finish always
// bound the trip; only overnight checkpoints STRICTLY inside the route create a
// boundary. Days are never persisted.
export function buildDays({ checkpoints = [], segments = [], cumulatives } = {}) {
  const cums = cumulatives || buildCumulatives(segments);
  const { cumulativeBySegment, segmentOffsets, totalM } = cums;
  if (!segments.length || totalM <= 0) return [];

  const samples = flatSamples(segments, cumulativeBySegment, segmentOffsets);

  const EPS = 1; // metre
  const seen = new Set();
  const warnings = [];
  const interior = [];
  for (const cp of checkpoints) {
    if (cp.kind !== "overnight") continue;
    const routeM = cp.anchor?.routeDistanceM;
    if (!Number.isFinite(routeM)) continue;
    if (routeM <= EPS || routeM >= totalM - EPS) continue; // coincides with Start/Finish
    const key = Math.round(routeM);
    if (seen.has(key)) {
      warnings.push(`Two overnight stops share the same position (~${(routeM / 1000).toFixed(1)} km).`);
      continue;
    }
    seen.add(key);
    interior.push({ routeM, cp });
  }
  interior.sort((a, b) => a.routeM - b.routeM);

  const boundaries = [
    { routeM: 0, label: "start" },
    ...interior.map((x) => ({ routeM: x.routeM, label: x.cp.id, name: x.cp.name })),
    { routeM: totalM, label: "finish" }
  ];

  const days = [];
  for (let i = 1; i < boundaries.length; i += 1) {
    const a = boundaries[i - 1];
    const b = boundaries[i];
    const range = statsForRange(samples, a.routeM, b.routeM);
    days.push({
      index: i,
      startRouteM: a.routeM,
      endRouteM: b.routeM,
      startBoundary: a.label,
      startName: a.name || (a.label === "start" ? "Start" : a.name),
      endBoundary: b.label,
      endName: b.name || (b.label === "finish" ? "Finish" : b.name),
      distanceM: Math.round(b.routeM - a.routeM),
      ...range
    });
  }
  return { days, warnings };
}
