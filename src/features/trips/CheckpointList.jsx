import React, { useState } from "react";
import { OFF_ROUTE_M } from "../../lib/trail.js";
import KindPicker from "./KindPicker.jsx";

const km = (m) => (m / 1000).toFixed(2);
const PREVIEW = 8;

// Checkpoint rows: category picker, inline name, route distance, elevation,
// note, off-route / ambiguous flags, delete. A long list stays manageable via
// per-category filter chips plus "show all" (rather than an overflow-scroll
// container, which would clip the category dropdown).
export default function CheckpointList({ checkpoints, onUpdate, onDelete, onHoverCheckpoint }) {
  const [expanded, setExpanded] = useState(false);

  if (checkpoints.length === 0) {
    return <p className="empty-hint">No checkpoints yet. Click the map or elevation profile to add one.</p>;
  }

  const shown = expanded ? checkpoints : checkpoints.slice(0, PREVIEW);
  const hidden = checkpoints.length - shown.length;

  return (
    <>
      <ul className="checkpoint-list">
        {shown.map((cp) => {
          const offRoute = cp.anchor.offsetM > OFF_ROUTE_M;
          return (
            <li
              key={cp.id}
              className="checkpoint-row"
              onMouseEnter={() => onHoverCheckpoint?.(cp.id)}
              onMouseLeave={() => onHoverCheckpoint?.(null)}
            >
              <KindPicker value={cp.kind} onChange={(k) => onUpdate(cp.id, { kind: k })} />
              <input
                className="cp-name"
                value={cp.name}
                placeholder="Checkpoint"
                onChange={(e) => onUpdate(cp.id, { name: e.target.value })}
              />
              <span className="cp-dist">{km(cp.anchor.routeDistanceM)} km</span>
              <span className="cp-ele">{cp.anchor.ele != null ? `${cp.anchor.ele} m` : "—"}</span>
              <input
                className="cp-note"
                value={cp.note}
                placeholder="Note"
                onChange={(e) => onUpdate(cp.id, { note: e.target.value })}
              />
              <span className="cp-actions">
                {offRoute && <span className="cp-flag off-route" title={`${cp.anchor.offsetM} m off route`}>off-route</span>}
                {cp.anchor.ambiguous && <span className="cp-flag ambiguous" title="Ambiguous position on a loop">?</span>}
                <button type="button" className="cp-delete" title="Delete checkpoint" onClick={() => onDelete(cp.id)}>
                  ×
                </button>
              </span>
            </li>
          );
        })}
      </ul>

      {(hidden > 0 || expanded) && checkpoints.length > PREVIEW && (
        <button type="button" className="link-btn cp-more" onClick={() => setExpanded((v) => !v)}>
          {expanded ? "Show fewer" : `Show all ${checkpoints.length}`}
        </button>
      )}
    </>
  );
}
