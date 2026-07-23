import { describe, it, expect } from "vitest";
import { parseInline, parseMarkdown } from "../markdown.js";

describe("parseInline", () => {
  it("splits bold, italic and code out of plain text", () => {
    expect(parseInline("a **b** c *i* d `x`")).toEqual([
      { t: "text", v: "a " },
      { t: "b", v: "b" },
      { t: "text", v: " c " },
      { t: "i", v: "i" },
      { t: "text", v: " d " },
      { t: "code", v: "x" }
    ]);
  });

  it("supports __bold__ and _italic_", () => {
    expect(parseInline("__B__ _i_")).toEqual([
      { t: "b", v: "B" },
      { t: "text", v: " " },
      { t: "i", v: "i" }
    ]);
  });

  it("leaves plain text untouched", () => {
    expect(parseInline("just text")).toEqual([{ t: "text", v: "just text" }]);
  });

  it("never emits markup for angle brackets (rendered as React text)", () => {
    const out = parseInline("<script>alert(1)</script>");
    expect(out).toEqual([{ t: "text", v: "<script>alert(1)</script>" }]);
  });
});

describe("parseMarkdown", () => {
  it("parses headings", () => {
    const [b] = parseMarkdown("## Day plan");
    expect(b.type).toBe("h");
    expect(b.level).toBe(2);
    expect(b.inline[0].v).toBe("Day plan");
  });

  it("groups consecutive bullets into one list", () => {
    const blocks = parseMarkdown("- one\n- two\n- three");
    expect(blocks).toHaveLength(1);
    expect(blocks[0].type).toBe("ul");
    expect(blocks[0].items).toHaveLength(3);
  });

  it("parses ordered lists with . or ) markers", () => {
    expect(parseMarkdown("1. a\n2) b")[0]).toMatchObject({ type: "ol" });
    expect(parseMarkdown("1. a\n2) b")[0].items).toHaveLength(2);
  });

  it("splits paragraphs on blank lines and keeps soft line breaks", () => {
    const blocks = parseMarkdown("one\ntwo\n\nthree");
    expect(blocks).toHaveLength(2);
    expect(blocks[0].type).toBe("p");
    expect(blocks[0].lines).toHaveLength(2);
    expect(blocks[1].lines).toHaveLength(1);
  });

  it("mixes prose and lists", () => {
    const blocks = parseMarkdown("Start early.\n- water at km 4\n- **col** at km 9\n\nDone.");
    expect(blocks.map((b) => b.type)).toEqual(["p", "ul", "p"]);
    expect(blocks[1].items[1][0]).toEqual({ t: "b", v: "col" });
  });

  it("handles empty / nullish input", () => {
    expect(parseMarkdown("")).toEqual([]);
    expect(parseMarkdown(null)).toEqual([]);
  });
});
