import { describe, it, expect } from "vitest";
import { buildPieSegments, polarToCartesian, describeDonutArc } from "../chart.js";

describe("buildPieSegments", () => {
  it("returns [] when total weight is zero", () => {
    expect(buildPieSegments([{ category: "A", weight: 0 }])).toEqual([]);
    expect(buildPieSegments([])).toEqual([]);
  });

  it("assigns contiguous from/to spanning 0..100 with percentages", () => {
    const segs = buildPieSegments([
      { category: "A", weight: 75 },
      { category: "B", weight: 25 }
    ]);
    expect(segs[0]).toMatchObject({ from: 0, to: 75, percent: 75 });
    expect(segs[1]).toMatchObject({ from: 75, to: 100, percent: 25 });
    expect(segs[segs.length - 1].to).toBeCloseTo(100, 6);
  });

  it("cycles colors when there are more categories than palette entries", () => {
    const rows = Array.from({ length: 9 }, (_, i) => ({ category: `C${i}`, weight: 1 }));
    const segs = buildPieSegments(rows);
    expect(segs[7].color).toBe(segs[0].color); // palette has 7 colors -> index 7 wraps to 0
  });
});

describe("polarToCartesian", () => {
  it("places 0deg at the top of the circle", () => {
    const { x, y } = polarToCartesian(100, 100, 50, 0);
    expect(x).toBeCloseTo(100, 6);
    expect(y).toBeCloseTo(50, 6);
  });
});

describe("describeDonutArc", () => {
  it("produces a closed SVG path with two arcs", () => {
    const d = describeDonutArc(110, 110, 105, 52, 0, 90);
    expect(d.startsWith("M ")).toBe(true);
    expect(d.match(/A /g)).toHaveLength(2);
    expect(d.endsWith("Z")).toBe(true);
  });

  it("sets the large-arc flag past 180 degrees", () => {
    const small = describeDonutArc(110, 110, 105, 52, 0, 90);
    const large = describeDonutArc(110, 110, 105, 52, 0, 270);
    expect(small).toContain("0 0 1");
    expect(large).toContain("0 1 1");
  });
});
