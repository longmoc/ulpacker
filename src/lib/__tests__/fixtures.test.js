// Golden-fixture tests.
//
// These pin the committed fixtures in ../../../fixtures/ so both sides of the
// port assert against identical bytes. A failure here means either a real
// regression in the route pipeline (trail.js, tripPackage.js) or an intentional
// change that requires regenerating the fixtures with `node fixtures/generate.mjs`
// — and, once the Swift port exists, updating its expectations in the same
// commit. Do not "fix" a failure by editing the expected numbers alone.

import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { validateTripPackage, computeContentHash } from "../tripPackage.js";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "../../../fixtures");
const load = (name) => JSON.parse(readFileSync(join(FIXTURES, "trips", name), "utf8"));

const synthetic = load("synthetic-ridge.trippackage.json");
const tmb = load("tmb-ccw.trippackage.json");

describe.each([
  ["synthetic-ridge", synthetic],
  ["tmb-ccw", tmb]
])("%s", (name, pkg) => {
  it("validates as a TripPackage v1", () => {
    expect(validateTripPackage(pkg)).toEqual({ ok: true, errors: [] });
  });

  it("hashes to the value stored in the file", () => {
    // Catches drift in canonicalJson or in any field the builder emits, which
    // is exactly what a Swift reimplementation could get subtly wrong.
    expect(computeContentHash(pkg)).toBe(pkg.contentHash);
  });

  it("has checkpoints ordered along the route", () => {
    const distances = pkg.checkpoints.map((c) => c.routeDistanceM);
    expect(distances).toEqual([...distances].sort((a, b) => a - b));
  });

  it("has a contiguous itinerary covering the whole route", () => {
    const days = pkg.itinerary;
    expect(days[0].startRouteM).toBe(0);
    expect(days.at(-1).endRouteM).toBe(pkg.plannedRoute.stats.distanceM);
    for (let i = 1; i < days.length; i += 1) {
      expect(days[i].startRouteM).toBe(days[i - 1].endRouteM);
    }
  });

  it("keeps every coordinate in range", () => {
    for (const seg of pkg.plannedRoute.segments) {
      for (const [lat, lng] of seg.points) {
        expect(lat).toBeGreaterThanOrEqual(-90);
        expect(lat).toBeLessThanOrEqual(90);
        expect(lng).toBeGreaterThanOrEqual(-180);
        expect(lng).toBeLessThanOrEqual(180);
      }
    }
  });
});

describe("synthetic-ridge fixture", () => {
  it("pins its content hash", () => {
    expect(synthetic.contentHash).toBe("032bf5c9be3fc1b2");
  });

  it("is small enough to reason about by hand", () => {
    expect(synthetic.plannedRoute.stats.pointCount).toBe(21);
    expect(synthetic.checkpoints).toHaveLength(1);
    expect(synthetic.checkpoints[0].kind).toBe("pass");
  });
});

describe("tmb-ccw fixture", () => {
  it("pins its content hash", () => {
    expect(tmb.contentHash).toBe("5c0f23f2c177c903");
  });

  it("is the real Tour du Mont Blanc, at the scale the companion must handle", () => {
    // ~165 km is the published TMB distance; this is the fixture's whole point,
    // so a pipeline change that silently halves the route fails loudly here.
    expect(tmb.plannedRoute.stats.distanceM).toBe(164231);
    expect(tmb.plannedRoute.stats.ascentM).toBe(11334);
    expect(tmb.plannedRoute.stats.pointCount).toBe(8561);
  });

  it("fuses the contiguous stage tracks into one segment", () => {
    // The source GPX has nine stage tracks that touch end-to-end; leaving them
    // separate would render phantom gaps and break route-distance continuity.
    expect(tmb.plannedRoute.stats.segmentCount).toBe(1);
  });

  it("carries the stage structure as nine itinerary days", () => {
    expect(tmb.itinerary).toHaveLength(9);
    expect(tmb.itinerary[0].startBoundary).toBe("start");
    expect(tmb.itinerary.at(-1).endBoundary).toBe("finish");
  });

  it("keeps waypoints and stage boundaries as checkpoints", () => {
    expect(tmb.checkpoints).toHaveLength(54);
    const kinds = new Set(tmb.checkpoints.map((c) => c.kind));
    expect(kinds.has("overnight")).toBe(true);
    // Waypoint-derived checkpoints keep positional ids so regeneration is stable.
    expect(tmb.checkpoints.some((c) => c.id.startsWith("cp_wpt_"))).toBe(true);
    expect(tmb.checkpoints.some((c) => c.id.startsWith("cp_bnd_"))).toBe(true);
  });

  it("stays within the app's own track limits", () => {
    // MAX_TRACK_POINTS is 50k and MAX_CHECKPOINTS_PER_TRIP is 100 — a fixture
    // that exceeded either would not survive a round trip through the app.
    expect(tmb.plannedRoute.stats.pointCount).toBeLessThanOrEqual(50_000);
    expect(tmb.checkpoints.length).toBeLessThanOrEqual(100);
  });
});
