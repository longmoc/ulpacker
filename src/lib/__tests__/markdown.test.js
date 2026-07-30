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

  describe("dividers", () => {
    it("reads a run of -, * or _ as a rule", () => {
      for (const src of ["---", "***", "___", "-----", "  ---  "]) {
        expect(parseMarkdown(src)).toEqual([{ type: "hr" }]);
      }
    });

    it("does not mistake a bullet for a rule, or the reverse", () => {
      // A bullet needs whitespace after its marker; a rule must stand alone.
      expect(parseMarkdown("- item").map((b) => b.type)).toEqual(["ul"]);
      expect(parseMarkdown("-- not a rule").map((b) => b.type)).toEqual(["p"]);
      expect(parseMarkdown("--- trailing text").map((b) => b.type)).toEqual(["p"]);
    });

    it("closes the paragraph it follows", () => {
      const blocks = parseMarkdown("Leave early.\n---\nCol is exposed.");
      expect(blocks.map((b) => b.type)).toEqual(["p", "hr", "p"]);
      expect(blocks[0].lines[0][0].v).toBe("Leave early.");
      expect(blocks[2].lines[0][0].v).toBe("Col is exposed.");
    });
  });

  describe("quotes", () => {
    it("gathers consecutive > lines into one quote, keeping inline marks", () => {
      const blocks = parseMarkdown("> Refuge is **full** in August.\n> Book ahead.");
      expect(blocks).toHaveLength(1);
      expect(blocks[0].type).toBe("quote");
      expect(blocks[0].lines).toHaveLength(2);
      expect(blocks[0].lines[0][1]).toEqual({ t: "b", v: "full" });
    });

    it("works with or without the space after >", () => {
      expect(parseMarkdown(">tight").map((b) => b.type)).toEqual(["quote"]);
      expect(parseMarkdown("> loose")[0].lines[0][0].v).toBe("loose");
      expect(parseMarkdown(">tight")[0].lines[0][0].v).toBe("tight");
    });

    it("a blank line ends the quote", () => {
      const blocks = parseMarkdown("> quoted\n\nplain again");
      expect(blocks.map((b) => b.type)).toEqual(["quote", "p"]);
    });

    it("closes the paragraph it follows", () => {
      const blocks = parseMarkdown("Note this.\n> warning\nback to prose");
      expect(blocks.map((b) => b.type)).toEqual(["p", "quote", "p"]);
    });
  });
});
