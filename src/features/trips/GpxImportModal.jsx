import React, { useMemo, useState } from "react";
import { buildTrackStats } from "../../lib/trail.js";

const km = (m) => (m / 1000).toFixed(1);

// Staged GPX preview. The user picks which tracks/routes to combine, in which
// order, plus whether to import waypoints/boundaries, before committing.
export default function GpxImportModal({ data, onConfirm, onClose }) {
  const { mode, fileName, candidates, waypoints, warnings } = data;
  const byId = useMemo(() => Object.fromEntries(candidates.map((c) => [c.id, c])), [candidates]);
  // `order` is the merge order (draggable); `selectedIds` is which are included.
  const [order, setOrder] = useState(() => candidates.map((c) => c.id));
  const [selectedIds, setSelectedIds] = useState(() => candidates.map((c) => c.id));
  const [importWaypoints, setImportWaypoints] = useState(waypoints.length > 0);
  const [addBoundaries, setAddBoundaries] = useState(true);

  // Chosen candidates, in merge order.
  const chosen = order.filter((oid) => selectedIds.includes(oid)).map((oid) => byId[oid]);

  // Offer boundary checkpoints only when merging ≥2 tracks that carry real,
  // distinct names (i.e. look like stages), never for unnamed/duplicate ways.
  const boundaryEligible =
    mode === "create" &&
    chosen.length >= 2 &&
    chosen.every((c) => c.named) &&
    new Set(chosen.map((c) => c.name)).size === chosen.length;
  const mergedSegments = chosen.flatMap((c) => c.segments);
  const stats = useMemo(
    () => (mergedSegments.length ? buildTrackStats(mergedSegments) : null),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [selectedIds, order]
  );
  const points = mergedSegments.reduce((n, s) => n + s.points.length, 0);
  const canConfirm = chosen.length > 0;

  const toggle = (oid) =>
    setSelectedIds((prev) => (prev.includes(oid) ? prev.filter((x) => x !== oid) : [...prev, oid]));

  const move = (oid, dir) =>
    setOrder((prev) => {
      const i = prev.indexOf(oid);
      const j = i + dir;
      if (j < 0 || j >= prev.length) return prev;
      const next = prev.slice();
      [next[i], next[j]] = [next[j], next[i]];
      return next;
    });

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal-panel gpx-modal" onClick={(e) => e.stopPropagation()}>
        <h3>{mode === "replace" ? "Replace track" : "Import trip"} — {fileName}</h3>

        {candidates.length > 1 && (
          <div className="gpx-candidates">
            <div className="gpx-candidates-head">
              <p className="field-label">
                {candidates.length} tracks/routes — checked ones combine in this order (reorder with ↑↓):
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
            {order.map((oid, idx) => {
              const c = byId[oid];
              return (
                <div key={oid} className="gpx-candidate-row">
                  <label className="gpx-candidate">
                    <input type="checkbox" checked={selectedIds.includes(oid)} onChange={() => toggle(oid)} />
                    <span>
                      <span className="gpx-candidate-order">{idx + 1}.</span> {c.name}{" "}
                      <em>({c.kind}, {c.segments.length} seg)</em>
                    </span>
                  </label>
                  <span className="gpx-reorder">
                    <button type="button" onClick={() => move(oid, -1)} disabled={idx === 0} title="Move up">
                      ↑
                    </button>
                    <button
                      type="button"
                      onClick={() => move(oid, 1)}
                      disabled={idx === order.length - 1}
                      title="Move down"
                    >
                      ↓
                    </button>
                  </span>
                </div>
              );
            })}
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

        {boundaryEligible && (
          <label className="gpx-waypoints">
            <input
              type="checkbox"
              checked={addBoundaries}
              onChange={(e) => setAddBoundaries(e.target.checked)}
            />
            Add an overnight checkpoint at each track boundary ({chosen.length - 1}, named from the tracks)
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
            onClick={() =>
              onConfirm({
                candidateIds: chosen.map((c) => c.id),
                importWaypoints,
                addBoundaries: addBoundaries && boundaryEligible
              })
            }
          >
            {mode === "replace" ? "Replace" : chosen.length > 1 ? `Create trip (${chosen.length} tracks)` : "Create trip"}
          </button>
        </div>
      </div>
    </div>
  );
}
