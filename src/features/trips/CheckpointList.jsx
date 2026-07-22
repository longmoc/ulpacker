import React from "react";
import { OFF_ROUTE_M } from "../../lib/trail.js";
import KindPicker from "./KindPicker.jsx";

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
        return (
          <li key={cp.id} className="checkpoint-row">
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
  );
}
