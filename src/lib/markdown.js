// Minimal, dependency-free Markdown subset for trip/day descriptions.
// Parses to a token tree (never to an HTML string) so the renderer can emit
// React elements — user text can therefore never inject markup.
//
// Supported: # / ## / ### headings, - * + bullet lists, 1. 1) ordered lists,
// > quotes, --- dividers, | tables |, **bold**, __bold__, *italic*, _italic_,
// `code`, [text](url) and bare http(s) links, blank-line paragraphs.

// A link is the one construct here that carries something executable, so its
// scheme is allow-listed rather than sanitised: anything that isn't plain web
// or mail (javascript:, data:, vbscript:, protocol-relative //host) is left as
// literal text instead of becoming an <a>.
const SAFE_SCHEME = /^(?:https?:|mailto:)/i;

export function safeHref(raw) {
  const url = String(raw ?? "").trim();
  if (!url) return null;
  // Control characters can hide a scheme from the test above ("java\nscript:").
  if (/[\u0000-\u001f\u007f]/.test(url)) return null;
  return SAFE_SCHEME.test(url) ? url : null;
}

// Order matters: the bracket form is tried before emphasis so a link's URL is
// consumed whole, and the bare-URL form comes last so `https://x` in backticks
// stays code.
const INLINE_RE = new RegExp(
  [
    /\[[^\]\n]+\]\([^()\s]*\)/.source, // [text](url)
    /\*\*[^*\n]+\*\*/.source,
    /__[^_\n]+__/.source,
    /\*[^*\n]+\*/.source,
    /_[^_\n]+_/.source,
    /`[^`\n]+`/.source,
    /https?:\/\/[^\s<>[\]()]+/.source // bare URL
  ].join("|"),
  "g"
);

const BRACKET_LINK = /^\[([^\]\n]+)\]\(\s*([^()\s]*)\s*\)$/;

// -> [{ t: "text" | "b" | "i" | "code", v } | { t: "a", v, href }]
export function parseInline(text) {
  const src = String(text ?? "");
  const out = [];
  let last = 0;
  let m;
  INLINE_RE.lastIndex = 0;
  while ((m = INLINE_RE.exec(src)) !== null) {
    if (m.index > last) out.push({ t: "text", v: src.slice(last, m.index) });
    const s = m[0];
    const bracket = BRACKET_LINK.exec(s);
    if (bracket) {
      const href = safeHref(bracket[2]);
      out.push(href ? { t: "a", v: bracket[1], href } : { t: "text", v: s });
    } else if (/^https?:\/\//i.test(s)) {
      // Sentence punctuation runs into a bare URL; keep it out of the target.
      const trail = (/[.,;:!?]+$/.exec(s) || [""])[0];
      const url = trail ? s.slice(0, -trail.length) : s;
      const href = safeHref(url);
      if (href) {
        out.push({ t: "a", v: url, href });
        if (trail) out.push({ t: "text", v: trail });
      } else {
        out.push({ t: "text", v: s });
      }
    } else if (s.startsWith("**") || s.startsWith("__")) out.push({ t: "b", v: s.slice(2, -2) });
    else if (s.startsWith("`")) out.push({ t: "code", v: s.slice(1, -1) });
    else out.push({ t: "i", v: s.slice(1, -1) });
    last = m.index + s.length;
  }
  if (last < src.length) out.push({ t: "text", v: src.slice(last) });
  return out.length ? out : [{ t: "text", v: "" }];
}

// Tables, minimal GFM: a header row, a separator row that sets alignment, then
// body rows. Both outer pipes are required — without them any prose containing
// a "|" would start looking like a table. No merged cells, no escaped pipes.
const TABLE_ROW = /^\s*\|.*\|\s*$/;
const TABLE_SEP = /^\s*\|(?:\s*:?-+:?\s*\|)+\s*$/;

const isTableStart = (lines, i) => TABLE_ROW.test(lines[i] || "") && TABLE_SEP.test(lines[i + 1] || "");

function tableCells(line) {
  return line.trim().replace(/^\|/, "").replace(/\|$/, "").split("|").map((c) => c.trim());
}

function cellAlign(sep) {
  const left = sep.startsWith(":");
  const right = sep.endsWith(":");
  if (left && right) return "center";
  if (right) return "right";
  return null; // default (left) — no inline style needed
}

const BULLET = /^\s*[-*+]\s+/;
const ORDERED = /^\s*\d+[.)]\s+/;
const HEADING = /^\s*(#{1,3})\s+(.*)$/;
const QUOTE = /^\s*>\s?/;
// A run of three or more, alone on the line. No conflict with BULLET, which
// requires whitespace after its marker ("- item"), so "---" can't be a list.
const RULE = /^\s*(-{3,}|\*{3,}|_{3,})\s*$/;

// -> [{ type: "h", level, inline } | { type: "ul" | "ol", items }
//     | { type: "quote", lines } | { type: "hr" } | { type: "p", lines }
//     | { type: "table", head, align, rows }]
export function parseMarkdown(text) {
  const lines = String(text ?? "").replace(/\r\n?/g, "\n").split("\n");
  const blocks = [];
  let i = 0;
  while (i < lines.length) {
    if (!lines[i].trim()) {
      i += 1;
      continue;
    }
    if (isTableStart(lines, i)) {
      const head = tableCells(lines[i]);
      const align = tableCells(lines[i + 1]).map(cellAlign);
      i += 2;
      const rows = [];
      while (i < lines.length && TABLE_ROW.test(lines[i])) {
        // Square off ragged rows against the header so the grid can't tear.
        const raw = tableCells(lines[i]);
        rows.push(Array.from({ length: head.length }, (_, c) => parseInline(raw[c] ?? "")));
        i += 1;
      }
      blocks.push({ type: "table", head: head.map(parseInline), align, rows });
      continue;
    }
    // Before BULLET: a divider is not a one-item list.
    if (RULE.test(lines[i])) {
      blocks.push({ type: "hr" });
      i += 1;
      continue;
    }
    if (QUOTE.test(lines[i])) {
      const quoted = [];
      while (i < lines.length && QUOTE.test(lines[i])) {
        quoted.push(parseInline(lines[i].replace(QUOTE, "")));
        i += 1;
      }
      blocks.push({ type: "quote", lines: quoted });
      continue;
    }
    const h = HEADING.exec(lines[i]);
    if (h) {
      blocks.push({ type: "h", level: h[1].length, inline: parseInline(h[2]) });
      i += 1;
      continue;
    }
    if (BULLET.test(lines[i])) {
      const items = [];
      while (i < lines.length && BULLET.test(lines[i])) {
        items.push(parseInline(lines[i].replace(BULLET, "")));
        i += 1;
      }
      blocks.push({ type: "ul", items });
      continue;
    }
    if (ORDERED.test(lines[i])) {
      const items = [];
      while (i < lines.length && ORDERED.test(lines[i])) {
        items.push(parseInline(lines[i].replace(ORDERED, "")));
        i += 1;
      }
      blocks.push({ type: "ol", items });
      continue;
    }
    const para = [];
    while (
      i < lines.length &&
      lines[i].trim() &&
      !BULLET.test(lines[i]) &&
      !ORDERED.test(lines[i]) &&
      !HEADING.test(lines[i]) &&
      !QUOTE.test(lines[i]) &&
      !RULE.test(lines[i]) &&
      !isTableStart(lines, i)
    ) {
      para.push(parseInline(lines[i]));
      i += 1;
    }
    blocks.push({ type: "p", lines: para });
  }
  return blocks;
}
