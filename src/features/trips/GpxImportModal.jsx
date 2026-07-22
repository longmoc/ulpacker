import React, { useMemo, useState } from "react";
import { buildTrackStats } from "../../lib/trail.js";

const km = (m) => (m / 1000).toFixed(1);

// Staged GPX preview. The user picks one candidate (a <trk> or <rte>; never
// merged) and whether to import waypoints as checkpoints before committing.
export default function GpxImportModal({ data, onConfirm, onClose }) {
  const { mode, fileName, candidates, waypoints, warnings } = data;
  const [candidateId, setCandidateId] = useState(candidates[0]?.id || "");
  const [importWaypoints, setImportWaypoints] = useState(waypoints.length > 0);

  const selected = candidates.find((c) => c.id === candidateId) || candidates[0];
  const stats = useMemo(() => (selected ? buildTrackStats(selected.segments) : null), [selected]);
  const points = selected ? selected.segments.reduce((n, s) => n + s.points.length, 0) : 0;

  const canConfirm = Boolean(selected);

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal-panel gpx-modal" onClick={(e) => e.stopPropagation()}>
        <h3>{mode === "replace" ? "Replace track" : "Import trip"} — {fileName}</h3>

        {candidates.length > 1 && (
          <div className="gpx-candidates">
            <p className="field-label">This file has {candidates.length} tracks/routes — pick one:</p>
            {candidates.map((c) => (
              <label key={c.id} className="gpx-candidate">
                <input
                  type="radio"
                  name="candidate"
                  checked={c.id === candidateId}
                  onChange={() => setCandidateId(c.id)}
                />
                <span>
                  {c.name} <em>({c.kind}, {c.segments.length} seg)</em>
                </span>
              </label>
            ))}
          </div>
        )}

        {stats && (
          <div className="gpx-summary">
            <span>{km(stats.distanceM)} km</span>
            {stats.ascentM != null && <span>+{stats.ascentM} / −{stats.descentM} m</span>}
            <span>{points.toLocaleString()} points</span>
            <span>{selected.segments.length} segment{selected.segments.length > 1 ? "s" : ""}</span>
          </div>
        )}

        {waypoints.length > 0 && (
          <label className="gpx-waypoints">
            <input
              type="checkbox"
              checked={importWaypoints}
              onChange={(e) => setImportWaypoints(e.target.checked)}
            />
            Import {waypoints.length} waypoint{waypoints.length > 1 ? "s" : ""} as checkpoints
          </label>
        )}

        {warnings.length > 0 && (
          <ul className="gpx-warnings">
            {warnings.map((w, i) => (
              <li key={i}>{w}</li>
            ))}
          </ul>
        )}

        <div className="modal-actions">
          <button type="button" onClick={onClose}>
            Cancel
          </button>
          <button
            type="button"
            className="primary"
            disabled={!canConfirm}
            onClick={() => onConfirm({ candidateId: selected.id, importWaypoints })}
          >
            {mode === "replace" ? "Replace" : "Create trip"}
          </button>
        </div>
      </div>
    </div>
  );
}
