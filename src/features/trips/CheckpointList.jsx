import React, { useState } from "react";
import { OFF_ROUTE_M, CHECKPOINT_KINDS, CHECKPOINT_KIND_KEYS } from "../../lib/trail.js";
import KindPicker from "./KindPicker.jsx";

const km = (m) => (m / 1000).toFixed(2);
const PREVIEW = 8;

// Checkpoint rows: category picker, inline name, route distance, elevation,
// note, off-route / ambiguous flags, delete. A long list stays manageable via
// per-category filter chips plus "show all" (rather than an overflow-scroll
// container, which would clip the category dropdown).
export default function CheckpointList({ checkpoints, onUpdate, onDelete, filter, onFilterChange, onHoverCheckpoint }) {
  const [expanded, setExpanded] = useState(false);
  const setFilter = (k) => onFilterChange?.(k);

  if (checkpoints.length === 0) {
    return <p className="empty-hint">No checkpoints yet. Click the map or elevation profile to add one.</p>;
  }

  const counts = {};
  for (const cp of checkpoints) {
    const k = CHECKPOINT_KINDS[cp.kind] ? cp.kind : "poi";
    counts[k] = (counts[k] || 0) + 1;
  }
  const matching = filter ? checkpoints.filter((cp) => (CHECKPOINT_KINDS[cp.kind] ? cp.kind : "poi") === filter) : checkpoints;
  const shown = expanded ? matching : matching.slice(0, PREVIEW);
  const hidden = matching.length - shown.length;

  return (
    <>
      <div className="cp-filters">
        <button
          type="button"
          className={`cp-chip ${filter === null ? "active" : ""}`}
          onClick={() => setFilter(null)}
        >
          All {checkpoints.length}
        </button>
        {CHECKPOINT_KIND_KEYS.filter((k) => counts[k]).map((k) => (
          <button
            key={k}
            type="button"
            title={CHECKPOINT_KINDS[k].label}
            className={`cp-chip kind-${k} ${filter === k ? "active" : ""}`}
            onClick={() => setFilter(filter === k ? null : k)}
          >
            {CHECKPOINT_KINDS[k].emoji} {counts[k]}
          </button>
        ))}
      </div>

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
              {offRoute && <span className="cp-flag off-route" title={`${cp.anchor.offsetM} m off route`}>off-route</span>}
              {cp.anchor.ambiguous && <span className="cp-flag ambiguous" title="Ambiguous position on a loop">?</span>}
              <button type="button" className="cp-delete" title="Delete checkpoint" onClick={() => onDelete(cp.id)}>
                ×
              </button>
            </li>
          );
        })}
      </ul>

      {(hidden > 0 || expanded) && matching.length > PREVIEW && (
        <button type="button" className="link-btn cp-more" onClick={() => setExpanded((v) => !v)}>
          {expanded ? "Show fewer" : `Show all ${matching.length}`}
        </button>
      )}
    </>
  );
}
