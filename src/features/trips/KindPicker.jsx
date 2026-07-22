import React, { useEffect, useRef, useState } from "react";
import { CHECKPOINT_KINDS, CHECKPOINT_KIND_KEYS } from "../../lib/trail.js";

// Compact category picker: the collapsed control shows only the emoji, the
// dropdown lists emoji + full label. (A native <select> can't show emoji-only
// when collapsed while keeping labels in the list.)
export default function KindPicker({ value, onChange }) {
  const kind = CHECKPOINT_KINDS[value] ? value : "poi";
  const [open, setOpen] = useState(false);
  const ref = useRef(null);

  useEffect(() => {
    if (!open) return undefined;
    const onDoc = (e) => {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false);
    };
    const onKey = (e) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", onDoc);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDoc);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div className={`kind-picker kind-${kind}`} ref={ref}>
      <button
        type="button"
        className="kind-picker-btn"
        title={CHECKPOINT_KINDS[kind].label}
        aria-label={`Category: ${CHECKPOINT_KINDS[kind].label}`}
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        <span className="kind-emoji">{CHECKPOINT_KINDS[kind].emoji}</span>
      </button>
      {open && (
        <div className="kind-menu" role="listbox">
          {CHECKPOINT_KIND_KEYS.map((k) => (
            <button
              key={k}
              type="button"
              role="option"
              aria-selected={k === kind}
              className={`kind-option ${k === kind ? "active" : ""}`}
              onClick={() => {
                onChange(k);
                setOpen(false);
              }}
            >
              <span className="kind-emoji">{CHECKPOINT_KINDS[k].emoji}</span> {CHECKPOINT_KINDS[k].label}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
