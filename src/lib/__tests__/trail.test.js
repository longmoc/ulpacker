// @vitest-environment jsdom
import { describe, it, expect } from "vitest";
import {
  parseGpx,
  haversine,
  buildCumulatives,
  buildTrackStats,
  snapToTrack,
  pointAtAnchor,
  decimateForRender,
  projectTrack,
  buildElevationSeries,
  detectAntimeridian,
  buildDays,
  joinContiguousSegments,
  evenSplitRouteM,
  suggestDaySplits,
  segmentBoundaryRouteMs,
  detectExtrema,
  classifyCheckpoint,
  sliceSegments,
  readableOn,
  DAY_COLORS,
  MAX_TRACK_POINTS
} from "../trail.js";

const gpxDoc = (inner) =>
  `<?xml version="1.0"?><gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">${inner}</gpx>`;

const trkpt = (lat, lng, ele) =>
  `<trkpt lat="${lat}" lon="${lng}">${ele == null ? "" : `<ele>${ele}</ele>`}</trkpt>`;

describe("parseGpx", () => {
  it("reads a single track with elevation", () => {
    const xml = gpxDoc(
      `<trk><name>Test</name><trkseg>${trkpt(45.0, 6.0, 1000)}${trkpt(45.001, 6.001, 1010)}</trkseg></trk>`
    );
    const { candidates, warnings } = parseGpx(xml);
    expect(candidates).toHaveLength(1);
    expect(candidates[0].kind).toBe("track");
    expect(candidates[0].name).toBe("Test");
    expect(candidates[0].segments[0].points).toHaveLength(2);
    expect(candidates[0].segments[0].points[0][2]).toBe(1000);
    expect(warnings).toHaveLength(0);
  });

  it("keeps two <trk> as separate candidates (never merged)", () => {
    const xml = gpxDoc(
      `<trk><name>A</name><trkseg>${trkpt(45, 6, 1)}${trkpt(45.001, 6, 2)}</trkseg></trk>` +
        `<trk><name>B</name><trkseg>${trkpt(46, 7, 1)}${trkpt(46.001, 7, 2)}</trkseg></trk>`
    );
    const { candidates } = parseGpx(xml);
    expect(candidates.map((c) => c.name)).toEqual(["A", "B"]);
  });

  it("keeps multiple <trkseg> within one track", () => {
    const xml = gpxDoc(
      `<trk><trkseg>${trkpt(45, 6, 1)}${trkpt(45.001, 6, 2)}</trkseg>` +
        `<trkseg>${trkpt(45.01, 6.01, 3)}${trkpt(45.011, 6.01, 4)}</trkseg></trk>`
    );
    const { candidates } = parseGpx(xml);
    expect(candidates[0].segments).toHaveLength(2);
  });

  it("reads <rte> as a one-segment candidate and does not merge with a track", () => {
    const xml = gpxDoc(
      `<trk><name>T</name><trkseg>${trkpt(45, 6, 1)}${trkpt(45.001, 6, 2)}</trkseg></trk>` +
        `<rte><name>R</name><rtept lat="10" lon="20"/><rtept lat="10.001" lon="20"/></rte>`
    );
    const { candidates } = parseGpx(xml);
    expect(candidates).toHaveLength(2);
    expect(candidates[1].kind).toBe("route");
    expect(candidates[1].name).toBe("R");
  });

  it("reads waypoints at file level", () => {
    const xml = gpxDoc(
      `<wpt lat="45" lon="6"><name>Camp</name></wpt>` +
        `<trk><trkseg>${trkpt(45, 6, 1)}${trkpt(45.001, 6, 2)}</trkseg></trk>`
    );
    const { waypoints } = parseGpx(xml);
    expect(waypoints).toEqual([{ name: "Camp", lat: 45, lng: 6 }]);
  });

  it("returns no candidates for a waypoint-only file", () => {
    const xml = gpxDoc(`<wpt lat="45" lon="6"><name>Camp</name></wpt>`);
    const { candidates, waypoints } = parseGpx(xml);
    expect(candidates).toHaveLength(0);
    expect(waypoints).toHaveLength(1);
  });

  it("drops a candidate with fewer than 2 valid points, with a warning", () => {
    const xml = gpxDoc(`<trk><name>Short</name><trkseg>${trkpt(45, 6, 1)}</trkseg></trk>`);
    const { candidates, warnings } = parseGpx(xml);
    expect(candidates).toHaveLength(0);
    expect(warnings.join(" ")).toMatch(/fewer than 2/);
  });

  it("drops individual out-of-range points", () => {
    const xml = gpxDoc(
      `<trk><trkseg>${trkpt(999, 6, 1)}${trkpt(45, 6, 2)}${trkpt(45.001, 6, 3)}</trkseg></trk>`
    );
    const { candidates } = parseGpx(xml);
    expect(candidates[0].segments[0].points).toHaveLength(2);
  });

  it("flags candidates with a real <name> vs. positional fallback", () => {
    const withName = gpxDoc(`<trk><name>Stage 1</name><trkseg>${trkpt(45, 6, 1)}${trkpt(45.001, 6, 2)}</trkseg></trk>`);
    expect(parseGpx(withName).candidates[0].named).toBe(true);
    const noName = gpxDoc(`<trk><trkseg>${trkpt(45, 6, 1)}${trkpt(45.001, 6, 2)}</trkseg></trk>`);
    const c = parseGpx(noName).candidates[0];
    expect(c.named).toBe(false);
    expect(c.name).toMatch(/track/i);
  });

  it("ignores namespace prefixes (reads by localName)", () => {
    const xml =
      `<?xml version="1.0"?><g:gpx xmlns:g="http://www.topografix.com/GPX/1/1">` +
      `<g:trk><g:trkseg><g:trkpt lat="45" lon="6"><g:ele>1</g:ele></g:trkpt>` +
      `<g:trkpt lat="45.001" lon="6"><g:ele>2</g:ele></g:trkpt></g:trkseg></g:trk></g:gpx>`;
    const { candidates } = parseGpx(xml);
    expect(candidates[0].segments[0].points).toHaveLength(2);
  });

  it("rejects a DOCTYPE declaration", () => {
    const xml = `<!DOCTYPE gpx>${gpxDoc("")}`;
    expect(() => parseGpx(xml)).toThrow(/document type/i);
  });

  it("rejects an ENTITY declaration", () => {
    const xml = `<!ENTITY foo "bar">${gpxDoc("")}`;
    expect(() => parseGpx(xml)).toThrow();
  });

  it("rejects malformed XML", () => {
    expect(() => parseGpx("<gpx><trk>")).toThrow(/valid XML/i);
  });

  it("rejects empty input", () => {
    expect(() => parseGpx("   ")).toThrow();
  });

  it("aborts when the point budget is exceeded", () => {
    let pts = "";
    for (let i = 0; i < 12; i += 1) pts += trkpt(45 + i * 0.0001, 6, 1);
    const xml = gpxDoc(`<trk><trkseg>${pts}</trkseg></trk>`);
    expect(() => parseGpx(xml, { maxPoints: 10 })).toThrow(/exceeds/);
  });

  it("exports a sane default point budget", () => {
    expect(MAX_TRACK_POINTS).toBeGreaterThan(1000);
  });
});

describe("haversine", () => {
  it("matches a known distance (~157 km per degree of latitude near equator... 1 deg lat = ~111 km)", () => {
    const d = haversine(0, 0, 1, 0);
    expect(d).toBeGreaterThan(110000);
    expect(d).toBeLessThan(112000);
  });
});

describe("buildTrackStats", () => {
  it("does not count the gap between segments in distance", () => {
    const near = [
      { points: [[45, 6, 100], [45, 6.001, 100]] } // ~78 m at this latitude
    ];
    const twoSegs = [
      { points: [[45, 6, 100], [45, 6.0005, 100]] },
      { points: [[45, 6.5, 100], [45, 6.5005, 100]] } // huge gap not counted
    ];
    const single = buildTrackStats(near).distanceM;
    const split = buildTrackStats(twoSegs).distanceM;
    expect(split).toBeLessThan(single * 2); // gap ignored, only two short edges
  });

  it("returns null elevation stats when no point has elevation", () => {
    const s = buildTrackStats([{ points: [[45, 6, null], [45.001, 6, null]] }]);
    expect(s.ascentM).toBeNull();
    expect(s.descentM).toBeNull();
    expect(s.minEle).toBeNull();
    expect(s.maxEle).toBeNull();
    expect(s.elevationCoverage).toBe(0);
  });

  it("reports partial elevation coverage", () => {
    const s = buildTrackStats([{ points: [[45, 6, 100], [45.001, 6, null]] }]);
    expect(s.elevationCoverage).toBe(0.5);
  });

  it("smooths jitter so ascent is not inflated", () => {
    const jittery = [{ points: [
      [45, 6, 100], [45.001, 6, 105], [45.002, 6, 100], [45.003, 6, 105], [45.004, 6, 100]
    ] }];
    const s = buildTrackStats(jittery);
    // Raw ascent would be ~15 m; smoothing keeps it well below that.
    expect(s.ascentM).toBeLessThan(10);
  });
});

describe("snapToTrack + pointAtAnchor", () => {
  const segments = [{ points: [[45, 6, 100], [45, 6.01, 110], [45, 6.02, 120]] }];

  it("snaps a nearby point onto an edge with the right offset", () => {
    const anchor = snapToTrack(segments, 45.0005, 6.005);
    expect(anchor.segmentIndex).toBe(0);
    expect(anchor.offsetM).toBeGreaterThan(0);
    expect(anchor.offsetM).toBeLessThan(100);
    expect(anchor.routeDistanceM).toBeGreaterThan(0);
    expect(anchor.sourceLat).toBe(45.0005);
  });

  it("keeps source coords for re-snapping and flags a far offset", () => {
    const anchor = snapToTrack(segments, 45.05, 6.005);
    expect(anchor.offsetM).toBeGreaterThan(200);
    expect(anchor.sourceLat).toBe(45.05);
  });

  it("does NOT flag a point on a straight track as ambiguous", () => {
    // ~2 km straight run; the adjacent edge is always close but not a loop.
    const pts = [];
    for (let i = 0; i <= 40; i += 1) pts.push([45, 6 + i * 0.0005, 100]);
    const straight = [{ points: pts }];
    const anchor = snapToTrack(straight, 45.0003, 6 + 20 * 0.0005);
    expect(anchor.ambiguous).toBe(false);
  });

  it("flags a point where the route loops back near itself", () => {
    // Two long parallel legs ~11 m apart (a hairpin): a point between them is
    // genuinely ambiguous — both legs are far apart ALONG the route.
    const out = [];
    const back = [];
    for (let i = 0; i <= 60; i += 1) {
      out.push([45.0, 6 + i * 0.0005, 100]); // leg going east
      back.push([45.0001, 6.03 - i * 0.0005, 100]); // leg coming back ~11 m north
    }
    const loop = [{ points: [...out, ...back] }];
    const anchor = snapToTrack(loop, 45.00005, 6.015); // between the two legs
    expect(anchor.ambiguous).toBe(true);
  });

  it("resolves an anchor unambiguously at a segment boundary", () => {
    const two = [
      { points: [[45, 6, 100], [45, 6.01, 100]] },
      { points: [[45.5, 6, 200], [45.5, 6.01, 200]] }
    ];
    const cums = buildCumulatives(two);
    const end0 = cums.cumulativeBySegment[0][1];
    const p = pointAtAnchor(two.map((s) => s), cums.cumulativeBySegment, {
      segmentIndex: 0,
      alongSegmentM: end0
    });
    expect(p.segmentIndex).toBe(0);
    expect(p.lat).toBeCloseTo(45, 3);
  });
});

describe("decimateForRender", () => {
  it("thins but keeps first and last point of a segment", () => {
    const pts = [];
    for (let i = 0; i < 100; i += 1) pts.push([45 + i * 0.001, 6, 100]);
    const out = decimateForRender([{ points: pts }], 10);
    expect(out[0].points.length).toBeLessThan(pts.length);
    expect(out[0].points[0]).toEqual(pts[0]);
    expect(out[0].points[out[0].points.length - 1]).toEqual(pts[pts.length - 1]);
  });

  it("leaves a small track untouched", () => {
    const segs = [{ points: [[45, 6, 1], [45.001, 6, 2]] }];
    expect(decimateForRender(segs, 1500)).toBe(segs);
  });
});

describe("projectTrack / buildElevationSeries", () => {
  const segments = [{ points: [[45, 6, 100], [45.01, 6.01, 200]] }];

  it("projects into the viewport with north up", () => {
    const { paths } = projectTrack(segments, 200, 100);
    expect(paths).toHaveLength(1);
    // higher latitude → smaller y (north up)
    expect(paths[0][1][1]).toBeLessThan(paths[0][0][1]);
  });

  it("builds a per-segment elevation series with break offsets", () => {
    const two = [
      { points: [[45, 6, 100], [45, 6.01, 110]] },
      { points: [[45.5, 6, 200], [45.5, 6.01, 210]] }
    ];
    const { cumulativeBySegment, segmentOffsets } = buildCumulatives(two);
    const { series, breaks } = buildElevationSeries(two, cumulativeBySegment, segmentOffsets);
    expect(series).toHaveLength(2);
    expect(breaks).toHaveLength(1);
    expect(breaks[0]).toBeGreaterThan(0);
  });
});

describe("joinContiguousSegments", () => {
  it("fuses segments whose endpoints touch into one continuous segment", () => {
    const segs = [
      { points: [[45, 6.0, 100], [45, 6.01, 110]] },
      { points: [[45, 6.01, 110], [45, 6.02, 120]] } // starts where the first ended
    ];
    const out = joinContiguousSegments(segs);
    expect(out).toHaveLength(1);
    expect(out[0].points).toHaveLength(3); // duplicate shared node dropped
  });

  it("keeps genuinely separate segments apart", () => {
    const segs = [
      { points: [[45, 6.0, 100], [45, 6.01, 110]] },
      { points: [[45.5, 6.0, 200], [45.5, 6.01, 210]] } // far away
    ];
    expect(joinContiguousSegments(segs)).toHaveLength(2);
  });

  it("leaves a single segment untouched", () => {
    const segs = [{ points: [[45, 6, 1], [45.001, 6, 2]] }];
    expect(joinContiguousSegments(segs)).toBe(segs);
  });
});

describe("evenSplitRouteM", () => {
  it("splits into N-1 interior points for a day count", () => {
    expect(evenSplitRouteM(12000, { days: 3 })).toEqual([4000, 8000]);
  });
  it("splits by target spacing", () => {
    expect(evenSplitRouteM(10000, { everyKm: 3 })).toEqual([3000, 6000, 9000]);
  });
  it("returns nothing when the route is shorter than one span", () => {
    expect(evenSplitRouteM(2000, { everyKm: 3 })).toEqual([]);
    expect(evenSplitRouteM(0, { days: 3 })).toEqual([]);
  });
});

describe("classifyCheckpoint", () => {
  it("classifies hiking waypoint names by category", () => {
    expect(classifyCheckpoint("Weather gate — Col du Bonhomme")).toBe("pass");
    expect(classifyCheckpoint("Hazard — Bionnassay glacier footbridge")).toBe("hazard");
    expect(classifyCheckpoint("Full resupply/gas — Courmayeur")).toBe("resupply");
    expect(classifyCheckpoint("Rest/water — Refuge des Mottets")).toBe("water");
    expect(classifyCheckpoint("Viewpoint — Mont de la Saxe balcony")).toBe("viewpoint");
    expect(classifyCheckpoint("Day 2 — Camping des Glaciers")).toBe("overnight");
    expect(classifyCheckpoint("Lunch/rest — Refuge de Miage")).toBe("food");
    expect(classifyCheckpoint("Backup shelter — Refuge de la Croix du Bonhomme")).toBe("refuge");
    expect(classifyCheckpoint("Route checkpoint — Dolonne")).toBe("poi");
    expect(classifyCheckpoint("")).toBe("poi");
  });
  it("prioritises hazard over other signals", () => {
    expect(classifyCheckpoint("Hazard — ladder near the water source")).toBe("hazard");
  });

  it("classifies transport stops", () => {
    expect(classifyCheckpoint("Day 4 — Arp Nouvaz shuttle boundary")).toBe("transport");
    expect(classifyCheckpoint("Train station — Chamonix")).toBe("transport");
    expect(classifyCheckpoint("Cable car — Brévent")).toBe("transport");
  });
});

describe("readableOn", () => {
  const contrast = (a, b) => {
    const lum = (h) => {
      const c = [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
        .map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4));
      return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    };
    const [L1, L2] = [lum(a), lum(b)].sort((x, y) => y - x);
    return (L1 + 0.05) / (L2 + 0.05);
  };
  it("black on white and white on black", () => {
    expect(readableOn("#ffffff")).toBe("#1c1c22");
    expect(readableOn("#000000")).toBe("#ffffff");
  });
  it("picks black text on the light hues", () => {
    expect(readableOn("#eda100")).toBe("#1c1c22"); // yellow
    expect(readableOn("#1baf7a")).toBe("#1c1c22"); // aqua
  });
  it("always returns the higher-contrast of black/white, clearing 3:1 for a bold badge", () => {
    for (const hex of DAY_COLORS) {
      const chosen = readableOn(hex);
      const other = chosen === "#ffffff" ? "#1c1c22" : "#ffffff";
      expect(contrast(chosen, hex)).toBeGreaterThanOrEqual(contrast(other, hex));
      expect(contrast(chosen, hex)).toBeGreaterThanOrEqual(3);
    }
  });
  it("falls back to white for a bad value", () => {
    expect(readableOn("nope")).toBe("#ffffff");
  });
});

describe("sliceSegments", () => {
  const segments = [{ points: [[45, 6.0, 100], [45, 6.02, 200], [45, 6.04, 150], [45, 6.06, 250]] }];
  const cums = buildCumulatives(segments);

  it("extracts only the requested route range", () => {
    const total = cums.totalM;
    const out = sliceSegments(segments, cums, total * 0.25, total * 0.75);
    expect(out).toHaveLength(1);
    const sliced = buildCumulatives(out).totalM;
    expect(sliced).toBeGreaterThan(total * 0.45);
    expect(sliced).toBeLessThan(total * 0.55);
  });

  it("returns the whole track for the full range", () => {
    const out = sliceSegments(segments, cums, 0, cums.totalM);
    expect(Math.round(buildCumulatives(out).totalM)).toBe(Math.round(cums.totalM));
  });

  it("returns nothing for an empty or inverted range", () => {
    expect(sliceSegments(segments, cums, 500, 500)).toEqual([]);
    expect(sliceSegments(segments, cums, 900, 100)).toEqual([]);
  });

  it("skips segments outside the range", () => {
    const two = [
      { points: [[45, 6.0, 0], [45, 6.02, 0]] },
      { points: [[45.5, 6.0, 0], [45.5, 6.02, 0]] }
    ];
    const c2 = buildCumulatives(two);
    const out = sliceSegments(two, c2, 0, c2.segmentLengths[0]);
    expect(out).toHaveLength(1);
  });
});

describe("segmentBoundaryRouteMs", () => {
  it("returns interior boundary distances for a multi-segment track", () => {
    const segs = [
      { points: [[45, 6.0, 0], [45, 6.02, 0]] },
      { points: [[45, 6.02, 0], [45, 6.04, 0]] },
      { points: [[45, 6.04, 0], [45, 6.06, 0]] }
    ];
    const b = segmentBoundaryRouteMs(segs);
    expect(b).toHaveLength(2);
    expect(b[0]).toBeGreaterThan(0);
    expect(b[1]).toBeGreaterThan(b[0]);
  });
  it("returns nothing for a single segment", () => {
    expect(segmentBoundaryRouteMs([{ points: [[45, 6, 0], [45, 6.01, 0]] }])).toEqual([]);
  });
});

describe("suggestDaySplits", () => {
  it("snaps an even split to a nearby segment boundary", () => {
    const plan = suggestDaySplits(12000, { days: 2 }, { boundaries: [6200] });
    expect(plan).toHaveLength(1);
    expect(plan[0].routeM).toBe(6200);
    expect(plan[0].source).toBe("boundary");
  });
  it("prefers an overnight checkpoint over a boundary at the same distance", () => {
    const plan = suggestDaySplits(12000, { days: 2 }, {
      checkpoints: [{ id: "c1", kind: "overnight", anchor: { routeDistanceM: 6100 } }],
      boundaries: [6050]
    });
    expect(plan[0].source).toBe("checkpoint");
    expect(plan[0].id).toBe("c1");
  });
  it("falls back to the even position when no anchor is near", () => {
    const plan = suggestDaySplits(12000, { days: 2 }, { boundaries: [500] });
    expect(plan[0].routeM).toBe(6000);
    expect(plan[0].source).toBe("even");
  });
  it("does not reuse the same anchor for two splits", () => {
    const plan = suggestDaySplits(12000, { days: 3 }, { boundaries: [4000] });
    const boundaryUses = plan.filter((p) => p.source === "boundary").length;
    expect(boundaryUses).toBeLessThanOrEqual(1);
  });
});

describe("detectExtrema", () => {
  it("finds a prominent high point and low point on a wave", () => {
    // one segment: up to 2000, down to 1000, up to 1500
    const pts = [];
    const profile = [];
    for (let i = 0; i <= 20; i += 1) profile.push(1000 + 1000 * Math.sin((Math.PI * i) / 20)); // hill to 2000
    for (let i = 1; i <= 20; i += 1) profile.push(2000 - 1000 * (i / 20)); // down to 1000
    for (let i = 1; i <= 20; i += 1) profile.push(1000 + 500 * (i / 20)); // up to 1500
    profile.forEach((ele, i) => pts.push([45 + i * 0.001, 6, Math.round(ele)]));
    const segments = [{ points: pts }];
    const out = detectExtrema(segments, buildCumulatives(segments), { minProminenceM: 100 });
    expect(out.some((e) => e.kind === "high")).toBe(true);
    expect(out.some((e) => e.kind === "low")).toBe(true);
    expect(out[0].prom).toBeUndefined(); // prom is stripped from the result
  });

  it("returns nothing without elevation", () => {
    const segments = [{ points: [[45, 6, null], [45.001, 6, null], [45.002, 6, null]] }];
    expect(detectExtrema(segments, buildCumulatives(segments))).toEqual([]);
  });
});

describe("detectAntimeridian", () => {
  it("flags a track spanning more than 180° of longitude", () => {
    expect(detectAntimeridian([{ points: [[0, -179, 0], [0, 179, 0]] }])).toBe(true);
  });
  it("passes a normal track", () => {
    expect(detectAntimeridian([{ points: [[45, 6, 0], [45, 6.5, 0]] }])).toBe(false);
  });
});

describe("buildDays", () => {
  // A ~straight 4 km track for predictable route distances.
  const segments = [{ points: [
    [45, 6.0, 100], [45, 6.02, 200], [45, 6.04, 150], [45, 6.06, 250]
  ] }];
  const cumulatives = buildCumulatives(segments);
  const total = cumulatives.totalM;

  const overnight = (routeDistanceM, id = "cp1", name = "Camp") => ({
    id, name, kind: "overnight", anchor: { routeDistanceM, segmentIndex: 0, alongSegmentM: routeDistanceM }
  });

  it("returns a single day with no overnight checkpoints", () => {
    const { days } = buildDays({ checkpoints: [], segments, cumulatives });
    expect(days).toHaveLength(1);
    expect(days[0].startBoundary).toBe("start");
    expect(days[0].endBoundary).toBe("finish");
  });

  it("splits into two days at one interior overnight stop", () => {
    const { days } = buildDays({ checkpoints: [overnight(total / 2)], segments, cumulatives });
    expect(days).toHaveLength(2);
    expect(days[0].endBoundary).toBe("cp1");
    expect(days[1].startBoundary).toBe("cp1");
  });

  it("ignores an overnight stop coinciding with Start/Finish (no 0 km day)", () => {
    const { days } = buildDays({ checkpoints: [overnight(0)], segments, cumulatives });
    expect(days).toHaveLength(1);
  });

  it("warns and de-dupes two overnight stops at the same position", () => {
    const { days, warnings } = buildDays({
      checkpoints: [overnight(total / 2, "a"), overnight(total / 2, "b")],
      segments,
      cumulatives
    });
    expect(days).toHaveLength(2);
    expect(warnings.length).toBeGreaterThan(0);
  });

  it("counts segment breaks within a day", () => {
    const two = [
      { points: [[45, 6, 100], [45, 6.02, 110]] },
      { points: [[45.5, 6, 200], [45.5, 6.02, 210]] }
    ];
    const cums = buildCumulatives(two);
    const { days } = buildDays({ checkpoints: [], segments: two, cumulatives: cums });
    expect(days[0].segmentBreaks).toBe(1);
  });
});
