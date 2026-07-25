// Builds an offline map pack for a trip.
//
//   node tools/build-offline-pack.mjs fixtures/trips/tmb-ccw.trippackage.json [--maxzoom 14]
//
// The corridor is derived from the route itself, so this works for any trip —
// nothing here knows about the Tour du Mont Blanc.
//
// Extraction runs through the `pmtiles` CLI against Protomaps' public daily
// planet build, which serves HTTP range requests: only the tiles inside the
// corridor are transferred, not the planet. Doing this on a laptop rather than
// in the app is deliberate (MOBILE_PLAN §5.2) — the PMTiles JavaScript library
// is a reader, and a client-side extractor is not a dependency worth carrying
// up a mountain.
//
// Output is a directory the app can import as-is:
//
//   <out>/tiles.pmtiles     the vector tiles
//   <out>/manifest.json     trip binding, coverage, size and content hash
//
// The hash is FNV-1a 64, the same algorithm TripPackage uses, so both sides of
// the port verify files the same way.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync, statSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const PLANET_BUILD = (date) => `https://build.protomaps.com/${date}.pmtiles`;
/// ~15 km each side of the route: enough to cover an escape down a valley or a
/// wrong turn onto the next path, without paying for tiles nobody will open.
const CORRIDOR_PADDING_KM = 15;

function fnv1a64(buffer) {
  const MASK = 0xffffffffffffffffn;
  const PRIME = 0x100000001b3n;
  let hash = 0xcbf29ce484222325n;
  for (const byte of buffer) {
    hash = ((hash ^ BigInt(byte)) * PRIME) & MASK;
  }
  return hash.toString(16).padStart(16, "0");
}

function corridorBBox(pkg) {
  let minLat = Infinity, maxLat = -Infinity, minLng = Infinity, maxLng = -Infinity;
  for (const segment of pkg.plannedRoute.segments) {
    for (const [lat, lng] of segment.points) {
      if (lat < minLat) minLat = lat;
      if (lat > maxLat) maxLat = lat;
      if (lng < minLng) minLng = lng;
      if (lng > maxLng) maxLng = lng;
    }
  }
  const midLat = (minLat + maxLat) / 2;
  const padLat = CORRIDOR_PADDING_KM / 111.32;
  // Longitude degrees shrink with latitude; padding by the latitude figure
  // would under-cover the route east and west, badly so at high latitude.
  const padLng = CORRIDOR_PADDING_KM / (111.32 * Math.cos((midLat * Math.PI) / 180));
  return [minLng - padLng, minLat - padLat, maxLng + padLng, maxLat + padLat];
}

/// Protomaps publishes a build per day; today's may not exist yet in every
/// timezone, so walk back until one answers.
async function latestBuildDate(maxDaysBack = 7) {
  for (let back = 0; back < maxDaysBack; back += 1) {
    const day = new Date(Date.now() - back * 86400000);
    const stamp = day.toISOString().slice(0, 10).replaceAll("-", "");
    const response = await fetch(PLANET_BUILD(stamp), { method: "HEAD" });
    if (response.ok) return stamp;
  }
  throw new Error("No Protomaps planet build responded in the last week.");
}

const args = process.argv.slice(2);
const packagePath = args.find((a) => !a.startsWith("--"));
if (!packagePath) {
  console.error("usage: node tools/build-offline-pack.mjs <trip-package.json> [--maxzoom N] [--out DIR]");
  process.exit(1);
}
const maxZoom = Number(args[args.indexOf("--maxzoom") + 1]) || 14;
const outDir = resolve(
  args.includes("--out") ? args[args.indexOf("--out") + 1] : "output/packs/pack"
);

const pkg = JSON.parse(readFileSync(packagePath, "utf8"));
const bbox = corridorBBox(pkg);
const build = await latestBuildDate();

console.log(`trip     ${pkg.tripId} rev ${pkg.revision} — ${pkg.trip.name}`);
console.log(`corridor ${bbox.map((n) => n.toFixed(4)).join(",")}  (+${CORRIDOR_PADDING_KM} km)`);
console.log(`source   ${PLANET_BUILD(build)}  maxzoom ${maxZoom}`);

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });
const tilesPath = join(outDir, "tiles.pmtiles");

execFileSync(
  "pmtiles",
  ["extract", PLANET_BUILD(build), tilesPath, `--bbox=${bbox.join(",")}`, `--maxzoom=${maxZoom}`],
  { stdio: ["ignore", "inherit", "inherit"] }
);

const tiles = readFileSync(tilesPath);
const manifest = {
  manifestVersion: 1,
  tripId: pkg.tripId,
  // Bound to the revision it was cut for: a re-routed trip needs new tiles, and
  // silently pairing old tiles with a new route is how someone ends up
  // navigating a corridor that no longer contains the path.
  tripRevision: pkg.revision,
  bbox,
  minZoom: 0,
  maxZoom,
  byteCount: tiles.length,
  contentHash: fnv1a64(tiles),
  source: PLANET_BUILD(build),
  createdAt: new Date().toISOString()
};
writeFileSync(join(outDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`\nwrote ${outDir}`);
console.log(`  tiles.pmtiles   ${(statSync(tilesPath).size / 1024 / 1024).toFixed(1)} MB`);
console.log(`  contentHash     ${manifest.contentHash}`);
