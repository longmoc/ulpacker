// Regenerates the golden fixtures in this directory.
//
//   node fixtures/generate.mjs path/to/trip.gpx
//
// These fixtures are the anti-drift medicine for the two route implementations
// (JS trail.js for the planner, Swift for the companion): both test suites
// assert against the same bytes, so a divergence shows up as a failing test
// rather than as a wrong position on a mountain.
//
// The pipeline deliberately mirrors confirmGpxImport() in App.jsx — parse,
// record segment boundaries before fusing, fuse contiguous ways, snap waypoints
// to the fused track — so the fixture is what the app would actually produce,
// not an idealised version of it.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { JSDOM } from "jsdom";

// parseGpx uses DOMParser; give it one before importing the module.
const dom = new JSDOM("");
globalThis.DOMParser = dom.window.DOMParser;

const {
  parseGpx,
  joinContiguousSegments,
  buildCumulatives,
  snapToTrack,
  classifyCheckpoint,
  segmentBoundaryRouteMs,
  anchorAtRouteM
} = await import("../src/lib/trail.js");
const { buildTripPackage, validateTripPackage } = await import("../src/lib/tripPackage.js");

const HERE = dirname(fileURLToPath(import.meta.url));

function buildFromGpx(gpxPath, { tripId, name }) {
  const xml = readFileSync(gpxPath, "utf8");
  const parsed = parseGpx(xml);

  // Boundaries are measured before fusing (fusion preserves total distance, so
  // the offsets stay valid) — same order of operations as the app.
  const preSegments = parsed.candidates.flatMap((c) => c.segments);
  const preCums = buildCumulatives(preSegments);
  const boundaryRouteM = [];
  let segCursor = 0;
  parsed.candidates.forEach((c, i) => {
    if (i > 0) boundaryRouteM.push({ routeM: preCums.segmentOffsets[segCursor], endsName: parsed.candidates[i - 1].name });
    segCursor += c.segments.length;
  });

  const segments = joinContiguousSegments(preSegments);
  const cums = buildCumulatives(segments);

  // Waypoints become checkpoints, classified by name exactly as on import.
  // Ids are positional, not random, so regenerating gives a stable file.
  const checkpoints = parsed.waypoints.map((wp, i) => ({
    id: `cp_wpt_${String(i + 1).padStart(3, "0")}`,
    name: wp.name,
    note: "",
    kind: classifyCheckpoint(wp.name),
    source: "waypoint",
    anchor: snapToTrack(segments, wp.lat, wp.lng, { cumulatives: cums })
  }));

  // One overnight stop per stage boundary, named after the stage ending there.
  boundaryRouteM.forEach((b, i) => {
    if (b.routeM <= 1 || b.routeM >= cums.totalM - 1) return;
    checkpoints.push({
      id: `cp_bnd_${String(i + 1).padStart(3, "0")}`,
      name: b.endsName,
      note: "",
      kind: "overnight",
      source: "manual",
      anchor: anchorAtRouteM(segments, cums, b.routeM)
    });
  });

  const trip = {
    id: tripId,
    name,
    description: "",
    startName: "",
    finishName: "",
    loop: false,
    startDayNumber: 1,
    boundaries: segmentBoundaryRouteMs(segments),
    dayNotes: {},
    extraDays: [],
    checkpoints
  };

  return {
    package: buildTripPackage(trip, { segments }, {
      // Fixed so regenerating an unchanged source produces an identical file.
      publishedAt: "2026-01-01T00:00:00.000Z"
    }),
    warnings: parsed.warnings
  };
}

// A tiny hand-built route for fast, readable assertions: one climb, one descent,
// one overnight stop. Big enough to produce two itinerary days, small enough to
// reason about by hand when a test fails.
function syntheticPackage() {
  const points = [];
  for (let i = 0; i <= 20; i += 1) {
    const ele = i <= 10 ? 1000 + i * 60 : 1600 - (i - 10) * 40;
    points.push([45.9 + i * 0.002, 6.8 + i * 0.002, ele]);
  }
  const segments = [{ points }];
  const cums = buildCumulatives(segments);
  const mid = anchorAtRouteM(segments, cums, Math.round(cums.totalM / 2));
  return buildTripPackage(
    {
      id: "trip_synthetic",
      name: "Synthetic Ridge",
      description: "Hand-built fixture: climb, col, descent.",
      startName: "Lower hut",
      finishName: "Valley",
      loop: false,
      startDayNumber: 1,
      dayNotes: { start: "Steady climb to the col." },
      extraDays: [],
      checkpoints: [
        { id: "cp_col", name: "Col", note: "Highest point", kind: "pass", source: "manual", anchor: mid }
      ]
    },
    { segments },
    { publishedAt: "2026-01-01T00:00:00.000Z" }
  );
}

function write(relPath, value) {
  const target = join(HERE, relPath);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, `${JSON.stringify(value)}\n`);
  const bytes = readFileSync(target).length;
  console.log(`${relPath}  ${(bytes / 1024).toFixed(1)} KB`);
  return target;
}

function check(label, pkg) {
  const result = validateTripPackage(pkg);
  if (!result.ok) {
    console.error(`${label} FAILED validation:`, result.errors);
    process.exitCode = 1;
  }
  return result.ok;
}

const synthetic = syntheticPackage();
check("synthetic", synthetic);
write("trips/synthetic-ridge.trippackage.json", synthetic);

const gpxPath = process.argv[2];
if (gpxPath) {
  const { package: pkg, warnings } = buildFromGpx(gpxPath, {
    tripId: "trip_tmb_ccw",
    name: "Tour du Mont Blanc (CCW)"
  });
  if (warnings?.length) console.log("parse warnings:", warnings);
  check("tmb", pkg);
  write("trips/tmb-ccw.trippackage.json", pkg);
  console.log(
    `  points=${pkg.plannedRoute.stats.pointCount}`,
    `segments=${pkg.plannedRoute.stats.segmentCount}`,
    `checkpoints=${pkg.checkpoints.length}`,
    `days=${pkg.itinerary.length}`,
    `distance=${(pkg.plannedRoute.stats.distanceM / 1000).toFixed(1)}km`
  );
} else {
  console.log("(no GPX argument — skipped the TMB fixture)");
}
