import React, { useState } from "react";

// Start / Finish legend entry: shows the trailhead name (or a fallback) next to
// the coloured dot, and turns into an input on click so it can be renamed.
export default function EndpointLabel({ dotClass, value, fallback, onSave }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value || "");

  const commit = () => {
    onSave((draft || "").trim());
    setEditing(false);
  };

  return (
    <span className="endpoint-label">
      <span className={`dot ${dotClass}`} />
      {editing ? (
        <input
          className="endpoint-input"
          autoFocus
          value={draft}
          placeholder={fallback}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={commit}
          onKeyDown={(e) => {
            if (e.key === "Enter") commit();
            if (e.key === "Escape") {
              setDraft(value || "");
              setEditing(false);
            }
          }}
        />
      ) : (
        <button
          type="button"
          className="endpoint-name"
          title="Rename"
          onClick={() => {
            setDraft(value || "");
            setEditing(true);
          }}
        >
          {value || fallback}
        </button>
      )}
    </span>
  );
}
