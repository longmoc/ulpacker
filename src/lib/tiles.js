// Slippy-map tile maths for saving a route's basemap on the device.
//
// Deliberately scoped to a *corridor* around the track rather than its bounding
// box: a bbox for a loop like the TMB is mostly land you never walk on, and the
// tile count grows fourfold per zoom level. Both the community tile servers this
// app uses (OpenStreetMap, OpenTopoMap) are donated capacity, so the job here is
// to fetch as few tiles as will actually be looked at.

// Cache the saved tiles under a name the service worker also knows.
export const TILE_CACHE = "ulpacker-tiles";

// Selectable basemaps. Topo (OpenTopoMap) adds contour lines + hillshade, which
// the plain OSM street map lacks. Both origins are allow-listed in the
// build-time CSP (img-src for the map, connect-src for the offline download).
export const BASEMAPS = {
  standard: {
    label: "Standard",
    url: "https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png",
    subdomains: "abc",
    maxZoom: 17,
    attribution: "© OpenStreetMap contributors"
  },
  topo: {
    label: "Topo",
    url: "https://{s}.tile.opentopomap.org/{z}/{x}/{y}.png",
    subdomains: "abc",
    maxZoom: 17,
    attribution: "© OpenTopoMap (CC-BY-SA) · © OpenStreetMap contributors"
  }
};

// Detail levels for the whole trail. Zoom 15 is as deep as this goes: each
// extra level quadruples the count, and covering 164 km at 16 would be ~3,200
// more tiles. That depth is offered per day instead (DEEP_ZOOM).
export const TILE_LEVELS = [
  { id: "overview", label: "Overview", zooms: [10, 11, 12, 13], hint: "Valleys and towns" },
  { id: "standard", label: "Standard", zooms: [10, 11, 12, 13, 14], hint: "Enough to follow the trail" },
  { id: "detailed", label: "Detailed", zooms: [10, 11, 12, 13, 14, 15], hint: "Paths and contours" }
];

// One level deeper, bought a day at a time (~440 tiles / 10 MB per TMB day).
// Where it isn't saved the service worker upscales the level above, so the map
// stays readable rather than going blank.
export const DEEP_ZOOM = 16;

// A raster PNG tile averages around this; used only to preview the download
// size before committing to it.
const AVG_TILE_BYTES = 22 * 1024;

// Refuse anything past this — a guard against a stray zoom level turning a
// polite download into a scrape.
export const MAX_TILES = 4000;

export function lngToTileX(lng, z) {
  return Math.floor(((lng + 180) / 360) * 2 ** z);
}

export function latToTileY(lat, z) {
  const rad = (lat * Math.PI) / 180;
  return Math.floor(((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2) * 2 ** z);
}

// Ground size of one tile, in metres, at this latitude and zoom.
export function tileSpanM(lat, z) {
  return (156543.03392 * Math.cos((lat * Math.PI) / 180)) / 2 ** z * 256;
}

// Every tile within `bufferM` of the track, for each zoom in `zooms`.
// Returns ["z/x/y", …] — a Set internally, so overlapping ring neighbours and
// repeated points collapse.
export function routeTiles(segments, { zooms = [10, 11, 12, 13, 14], bufferM = 1500 } = {}) {
  const out = new Set();
  for (const z of zooms) {
    for (const seg of segments || []) {
      const pts = seg.points || [];
      if (pts.length === 0) continue;
      // Step along the track at roughly a third of a tile so no gap is left
      // between sampled points, however dense or sparse the GPX is.
      const span = tileSpanM(pts[0][0], z);
      const ring = Math.max(1, Math.ceil(bufferM / span));
      for (const p of pts) {
        const x = lngToTileX(p[1], z);
        const y = latToTileY(p[0], z);
        for (let dx = -ring; dx <= ring; dx += 1) {
          for (let dy = -ring; dy <= ring; dy += 1) {
            out.add(`${z}/${x + dx}/${y + dy}`);
          }
        }
      }
    }
  }
  return [...out];
}

// Sample the track down before tiling: at low zoom a 8.5k-point GPX would ask
// the same question thousands of times for one tile.
export function sampleForTiles(segments, maxPoints = 1200) {
  const total = (segments || []).reduce((n, s) => n + (s.points?.length || 0), 0);
  if (total <= maxPoints) return segments || [];
  const step = Math.ceil(total / maxPoints);
  return (segments || []).map((seg) => {
    const pts = seg.points || [];
    const kept = pts.filter((_, i) => i % step === 0);
    // Always keep the last point so the corridor reaches the finish.
    if (pts.length && kept[kept.length - 1] !== pts[pts.length - 1]) kept.push(pts[pts.length - 1]);
    return { points: kept };
  });
}

export function estimateBytes(tileCount) {
  return tileCount * AVG_TILE_BYTES;
}

export function formatBytes(bytes) {
  if (bytes >= 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
  if (bytes >= 1024 * 1024) return `${Math.round(bytes / 1024 / 1024)} MB`;
  return `${Math.round(bytes / 1024)} KB`;
}

// Fill a tile-server URL template. Subdomains are rotated so the requests
// spread over the server pool the way Leaflet's own {s} does.
export function tileUrl(template, key, subdomains = "abc") {
  const [z, x, y] = key.split("/");
  const s = subdomains[(Number(x) + Number(y)) % subdomains.length];
  return template
    .replace("{s}", s)
    .replace("{z}", z)
    .replace("{x}", x)
    .replace("{y}", y);
}
