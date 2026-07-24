import React, { useState } from "react";

// Start / Finish legend entry: an icon + the trailhead name. Click the name to
// rename it inline. `disabled` (used when a loop binds finish to start) shows
// the name as static text.
export default function EndpointLabel({ className = "", icon, value, fallback, onSave, disabled }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState(value || "");

  const commit = () => {
    onSave((draft || "").trim());
    setEditing(false);
  };

  return (
    <span className={`endpoint-label ${className}`}>
      {icon}
      {editing && !disabled ? (
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
      ) : disabled ? (
        <span className="endpoint-name disabled">{value || fallback}</span>
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
