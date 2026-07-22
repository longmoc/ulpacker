import React, { useMemo, useState } from "react";
import { buildTrackStats } from "../../lib/trail.js";

const km = (m) => (m / 1000).toFixed(1);

// Staged GPX preview. The user picks one candidate (a <trk> or <rte>; never
// merged) and whether to import waypoints as checkpoints before committing.
export default function GpxImportModal({ data, onConfirm, onClose }) {
  const { mode, fileName, candidates, waypoints, warnings } = data;
  // Default to all candidates selected; they merge in file order.
  const [selectedIds, setSelectedIds] = useState(() => candidates.map((c) => c.id));
  const [importWaypoints, setImportWaypoints] = useState(waypoints.length > 0);

  // Keep file order regardless of toggle order.
  const chosen = candidates.filter((c) => selectedIds.includes(c.id));
  const mergedSegments = chosen.flatMap((c) => c.segments);
  const stats = useMemo(
    () => (mergedSegments.length ? buildTrackStats(mergedSegments) : null),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [selectedIds]
  );
  const points = mergedSegments.reduce((n, s) => n + s.points.length, 0);
  const canConfirm = chosen.length > 0;

  const toggle = (id) =>
    setSelectedIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal-panel gpx-modal" onClick={(e) => e.stopPropagation()}>
        <h3>{mode === "replace" ? "Replace track" : "Import trip"} — {fileName}</h3>

        {candidates.length > 1 && (
          <div className="gpx-candidates">
            <div className="gpx-candidates-head">
              <p className="field-label">
                This file has {candidates.length} tracks/routes — checked ones are combined in order:
              </p>
              <button
                type="button"
                className="link-btn"
                onClick={() =>
                  setSelectedIds((prev) =>
                    prev.length === candidates.length ? [] : candidates.map((c) => c.id)
                  )
                }
              >
                {selectedIds.length === candidates.length ? "Clear all" : "Select all"}
              </button>
            </div>
            {candidates.map((c, i) => (
              <label key={c.id} className="gpx-candidate">
                <input type="checkbox" checked={selectedIds.includes(c.id)} onChange={() => toggle(c.id)} />
                <span>
                  <span className="gpx-candidate-order">{i + 1}.</span> {c.name}{" "}
                  <em>({c.kind}, {c.segments.length} seg)</em>
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
            <span>{mergedSegments.length} segment{mergedSegments.length > 1 ? "s" : ""}</span>
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
            onClick={() => onConfirm({ candidateIds: chosen.map((c) => c.id), importWaypoints })}
          >
            {mode === "replace" ? "Replace" : chosen.length > 1 ? `Create trip (${chosen.length} tracks)` : "Create trip"}
          </button>
        </div>
      </div>
    </div>
  );
}
