// Minimal, dependency-free Markdown subset for trip/day descriptions.
// Parses to a token tree (never to an HTML string) so the renderer can emit
// React elements — user text can therefore never inject markup.
//
// Supported: # / ## / ### headings, - * + bullet lists, 1. 1) ordered lists,
// **bold**, __bold__, *italic*, _italic_, `code`, blank-line paragraphs.

const INLINE_RE = /(\*\*[^*\n]+\*\*|__[^_\n]+__|\*[^*\n]+\*|_[^_\n]+_|`[^`\n]+`)/g;

// -> [{ t: "text" | "b" | "i" | "code", v }]
export function parseInline(text) {
  const src = String(text ?? "");
  const out = [];
  let last = 0;
  let m;
  INLINE_RE.lastIndex = 0;
  while ((m = INLINE_RE.exec(src)) !== null) {
    if (m.index > last) out.push({ t: "text", v: src.slice(last, m.index) });
    const s = m[0];
    if (s.startsWith("**") || s.startsWith("__")) out.push({ t: "b", v: s.slice(2, -2) });
    else if (s.startsWith("`")) out.push({ t: "code", v: s.slice(1, -1) });
    else out.push({ t: "i", v: s.slice(1, -1) });
    last = m.index + s.length;
  }
  if (last < src.length) out.push({ t: "text", v: src.slice(last) });
  return out.length ? out : [{ t: "text", v: "" }];
}

const BULLET = /^\s*[-*+]\s+/;
const ORDERED = /^\s*\d+[.)]\s+/;
const HEADING = /^\s*(#{1,3})\s+(.*)$/;

// -> [{ type: "h", level, inline } | { type: "ul" | "ol", items } | { type: "p", lines }]
export function parseMarkdown(text) {
  const lines = String(text ?? "").replace(/\r\n?/g, "\n").split("\n");
  const blocks = [];
  let i = 0;
  while (i < lines.length) {
    if (!lines[i].trim()) {
      i += 1;
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
      !HEADING.test(lines[i])
    ) {
      para.push(parseInline(lines[i]));
      i += 1;
    }
    blocks.push({ type: "p", lines: para });
  }
  return blocks;
}
