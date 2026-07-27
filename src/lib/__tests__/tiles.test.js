import { describe, it, expect } from "vitest";
import {
  lngToTileX,
  latToTileY,
  tileSpanM,
  routeTiles,
  sampleForTiles,
  tileUrl,
  formatBytes,
  BASEMAPS,
  TILE_LEVELS
} from "../tiles.js";

describe("tile coordinates", () => {
  it("maps the origin corner to tile 0/0 and the antimeridian to the last column", () => {
    expect(lngToTileX(-180, 4)).toBe(0);
    expect(lngToTileX(179.9, 4)).toBe(15);
    // Latitude 0 sits on the seam between the two middle rows.
    expect(latToTileY(0.0001, 4)).toBe(7);
  });

  it("places a known point on the documented tile (Chamonix, z12)", () => {
    expect(lngToTileX(6.8694, 12)).toBe(2126);
    expect(latToTileY(45.9237, 12)).toBe(1458);
  });

  it("halves the ground span with each zoom level", () => {
    const a = tileSpanM(46, 12);
    const b = tileSpanM(46, 13);
    expect(a / b).toBeCloseTo(2, 6);
  });
});

describe("routeTiles", () => {
  const line = { points: [[46.0, 6.9, 1000], [46.01, 6.91, 1100], [46.02, 6.92, 1200]] };

  it("covers every zoom asked for, and nothing else", () => {
    const keys = routeTiles([line], { zooms: [12, 13], bufferM: 100 });
    const zooms = new Set(keys.map((k) => k.split("/")[0]));
    expect([...zooms].sort()).toEqual(["12", "13"]);
  });

  it("includes the tile each point sits on", () => {
    const keys = routeTiles([line], { zooms: [14], bufferM: 1 });
    for (const p of line.points) {
      expect(keys).toContain(`14/${lngToTileX(p[1], 14)}/${latToTileY(p[0], 14)}`);
    }
  });

  it("grows with the corridor width and de-duplicates overlaps", () => {
    const narrow = routeTiles([line], { zooms: [13], bufferM: 100 });
    const wide = routeTiles([line], { zooms: [13], bufferM: 4000 });
    expect(wide.length).toBeGreaterThan(narrow.length);
    expect(new Set(wide).size).toBe(wide.length);
  });

  it("returns nothing for an empty track", () => {
    expect(routeTiles([], { zooms: [12] })).toEqual([]);
    expect(routeTiles([{ points: [] }], { zooms: [12] })).toEqual([]);
  });

  it("stays bounded for a real-length trail at the deepest offered level", () => {
    // ~160 km of track, one point every ~20 m.
    const points = Array.from({ length: 8000 }, (_, i) => [45.9 + i * 0.00002, 6.8 + i * 0.00003, 1000]);
    const deepest = TILE_LEVELS[TILE_LEVELS.length - 1];
    const keys = routeTiles(sampleForTiles([{ points }]), { zooms: deepest.zooms });
    expect(keys.length).toBeLessThan(4000);
  });
});

describe("sampleForTiles", () => {
  it("leaves a short track alone", () => {
    const segs = [{ points: [[1, 2, 3], [4, 5, 6]] }];
    expect(sampleForTiles(segs, 100)).toBe(segs);
  });

  it("thins a long track but keeps the final point", () => {
    const points = Array.from({ length: 5000 }, (_, i) => [45 + i * 0.0001, 6, 0]);
    const [seg] = sampleForTiles([{ points }], 500);
    expect(seg.points.length).toBeLessThanOrEqual(502);
    expect(seg.points[seg.points.length - 1]).toBe(points[points.length - 1]);
  });
});

describe("tileUrl", () => {
  it("fills the template and rotates subdomains deterministically", () => {
    const url = tileUrl(BASEMAPS.standard.url, "12/2126/1453", "abc");
    expect(url).toBe("https://a.tile.openstreetmap.org/12/2126/1453.png");
    // x+y = 3579 → 3579 % 3 = 0 → "a"; a neighbour lands on a different host.
    expect(tileUrl(BASEMAPS.standard.url, "12/2127/1453", "abc")).toContain("//b.");
  });

  it("builds topo URLs from the same key", () => {
    expect(tileUrl(BASEMAPS.topo.url, "12/2126/1453")).toContain("tile.opentopomap.org/12/2126/1453.png");
  });
});

describe("formatBytes", () => {
  it("scales the unit to the size", () => {
    expect(formatBytes(500 * 1024)).toBe("500 KB");
    expect(formatBytes(12 * 1024 * 1024)).toBe("12 MB");
    expect(formatBytes(3 * 1024 * 1024 * 1024)).toBe("3.0 GB");
  });
});
