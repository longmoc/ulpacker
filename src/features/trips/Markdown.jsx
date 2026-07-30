import React from "react";
import { parseMarkdown } from "../../lib/markdown.js";

function Inline({ tokens }) {
  return (
    <>
      {tokens.map((tk, i) => {
        if (tk.t === "b") return <strong key={i}>{tk.v}</strong>;
        if (tk.t === "i") return <em key={i}>{tk.v}</em>;
        if (tk.t === "code") return <code key={i}>{tk.v}</code>;
        // noopener/noreferrer: a new tab must not get a handle on this one.
        if (tk.t === "a")
          return (
            <a key={i} href={tk.href} target="_blank" rel="noopener noreferrer nofollow">
              {tk.v}
            </a>
          );
        return <React.Fragment key={i}>{tk.v}</React.Fragment>;
      })}
    </>
  );
}

// Renders the Markdown subset as React elements (never raw HTML).
export default function Markdown({ text }) {
  const blocks = parseMarkdown(text);
  return (
    <div className="md">
      {blocks.map((b, i) => {
        if (b.type === "h") {
          const Tag = `h${Math.min(6, b.level + 3)}`;
          return (
            <Tag key={i}>
              <Inline tokens={b.inline} />
            </Tag>
          );
        }
        if (b.type === "hr") return <hr key={i} />;
        if (b.type === "quote") {
          return (
            <blockquote key={i}>
              {b.lines.map((ln, j) => (
                <React.Fragment key={j}>
                  {j > 0 && <br />}
                  <Inline tokens={ln} />
                </React.Fragment>
              ))}
            </blockquote>
          );
        }
        if (b.type === "ul" || b.type === "ol") {
          const Tag = b.type;
          return (
            <Tag key={i}>
              {b.items.map((it, j) => (
                <li key={j}>
                  <Inline tokens={it} />
                </li>
              ))}
            </Tag>
          );
        }
        return (
          <p key={i}>
            {b.lines.map((ln, j) => (
              <React.Fragment key={j}>
                {j > 0 && <br />}
                <Inline tokens={ln} />
              </React.Fragment>
            ))}
          </p>
        );
      })}
    </div>
  );
}
