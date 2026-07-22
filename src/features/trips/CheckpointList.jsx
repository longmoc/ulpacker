import React from "react";
import { OFF_ROUTE_M } from "../../lib/trail.js";

const km = (m) => (m / 1000).toFixed(2);

// Checkpoint rows: inline name, route distance, elevation, overnight toggle,
// note, off-route / ambiguous flags, delete. Everything is reachable without
// the graphics (mobile-friendly).
export default function CheckpointList({ checkpoints, onUpdate, onDelete }) {
  if (checkpoints.length === 0) {
    return <p className="empty-hint">No checkpoints yet. Click the elevation profile to add one.</p>;
  }
  return (
    <ul className="checkpoint-list">
      {checkpoints.map((cp) => {
        const offRoute = cp.anchor.offsetM > OFF_ROUTE_M;
        return (
          <li key={cp.id} className="checkpoint-row">
            <button
              type="button"
              className={`moon-btn ${cp.overnight ? "active" : ""}`}
              title={cp.overnight ? "Overnight stop" : "Mark as overnight stop"}
              aria-pressed={cp.overnight}
              onClick={() => onUpdate(cp.id, { overnight: !cp.overnight })}
            >
              🌙
            </button>
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
