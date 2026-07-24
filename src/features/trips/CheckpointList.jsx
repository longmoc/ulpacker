import React, { useState } from "react";
import { OFF_ROUTE_M } from "../../lib/trail.js";
import KindPicker from "./KindPicker.jsx";
import { PinIcon, PeakIcon, TargetIcon } from "../../components/icons.jsx";

const PREVIEW = 8;

// Distance label with a sign (relative distances can be negative).
const fmtKm = (m) => {
  const km = m / 1000;
  return `${km < 0 ? "−" : ""}${Math.abs(km).toFixed(2)}`;
};

// Checkpoint rows, styled like the pack list. Ticking the target on the left
// (max 2) reframes the distances: 1 tick → distances relative to it (signed);
// 2 ticks → the pair anchors a range (rows between show distance from the
// first) that the map/profile also isolate.
export default function CheckpointList({
  checkpoints,
  onUpdate,
  onDelete,
  onHoverCheckpoint,
  anchorPoints = [],
  onToggleAnchor
}) {
  const [expanded, setExpanded] = useState(false);

  if (checkpoints.length === 0) {
    return <p className="empty-hint">No checkpoints yet. Click the map or elevation profile to add one.</p>;
  }

  const shown = expanded ? checkpoints : checkpoints.slice(0, PREVIEW);
  const hidden = checkpoints.length - shown.length;

  const a = anchorPoints[0];
  const b = anchorPoints[1];

  const displayM = (routeM) => {
    if (anchorPoints.length === 1) return routeM - a.routeM; // signed, relative to the anchor
    if (anchorPoints.length === 2) {
      return routeM >= a.routeM - 1 && routeM <= b.routeM + 1 ? routeM - a.routeM : routeM;
    }
    return routeM;
  };

  return (
    <>
      <ul className="checkpoint-list">
        {shown.map((cp) => {
          const offRoute = cp.anchor.offsetM > OFF_ROUTE_M;
          const r = cp.anchor.routeDistanceM;
          const isA = a && cp.id === a.id;
          const isB = b && cp.id === b.id;
          const ticked = isA || isB;
          const between = anchorPoints.length === 2 && r > a.routeM + 1 && r < b.routeM - 1;
          const railTop = anchorPoints.length === 2 && (isB || between);
          const railBottom = anchorPoints.length === 2 && (isA || between);
          const relative =
            anchorPoints.length === 1 || (anchorPoints.length === 2 && (isA || isB || between));
          const tickCls = [
            "cp-tick",
            ticked ? "on" : "",
            railTop ? "rail-top" : "",
            railBottom ? "rail-bottom" : "",
            isB ? "arrow" : ""
          ]
            .filter(Boolean)
            .join(" ");
          return (
            <li
              key={cp.id}
              className="checkpoint-row"
              onMouseEnter={() => onHoverCheckpoint?.(cp.id)}
              onMouseLeave={() => onHoverCheckpoint?.(null)}
            >
              <span className={tickCls}>
                <button
                  type="button"
                  className="cp-tick-btn"
                  title={ticked ? "Unset reference point" : "Set as reference point"}
                  aria-pressed={ticked}
                  onClick={() => onToggleAnchor?.(cp.id)}
                >
                  <TargetIcon size={15} />
                </button>
              </span>
              <KindPicker value={cp.kind} onChange={(k) => onUpdate(cp.id, { kind: k })} />
              <input
                className="cp-name"
                value={cp.name}
                placeholder="Checkpoint"
                onChange={(e) => onUpdate(cp.id, { name: e.target.value })}
              />
              <span className={`cp-metric cp-dist ${relative ? "relative" : ""}`} title="Distance">
                <PinIcon size={12} />
                {fmtKm(displayM(r))}
                <em>km</em>
              </span>
              <span className="cp-metric cp-ele" title="Elevation">
                <PeakIcon size={12} />
                {cp.anchor.ele != null ? cp.anchor.ele : "—"}
                {cp.anchor.ele != null && <em>m</em>}
              </span>
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
