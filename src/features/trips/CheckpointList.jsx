import React from "react";
import { OFF_ROUTE_M, CHECKPOINT_KINDS, CHECKPOINT_KIND_KEYS } from "../../lib/trail.js";

const km = (m) => (m / 1000).toFixed(2);

// Checkpoint rows: category selector, inline name, route distance, elevation,
// note, off-route / ambiguous flags, delete. Everything is reachable without
// the graphics (mobile-friendly). The "overnight" category drives the itinerary.
export default function CheckpointList({ checkpoints, onUpdate, onDelete }) {
  if (checkpoints.length === 0) {
    return <p className="empty-hint">No checkpoints yet. Click the map or elevation profile to add one.</p>;
  }
  return (
    <ul className="checkpoint-list">
      {checkpoints.map((cp) => {
        const offRoute = cp.anchor.offsetM > OFF_ROUTE_M;
        const kind = CHECKPOINT_KINDS[cp.kind] ? cp.kind : "poi";
        return (
          <li key={cp.id} className="checkpoint-row">
            <select
              className={`cp-kind kind-${kind}`}
              value={kind}
              title={CHECKPOINT_KINDS[kind].label}
              onChange={(e) => onUpdate(cp.id, { kind: e.target.value })}
            >
              {CHECKPOINT_KIND_KEYS.map((k) => (
                <option key={k} value={k}>
                  {CHECKPOINT_KINDS[k].emoji} {CHECKPOINT_KINDS[k].label}
                </option>
              ))}
            </select>
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
  );
}
