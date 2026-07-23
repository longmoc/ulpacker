import React, { useMemo, useRef, useState } from "react";
import { buildCumulatives, buildElevationSeries, CHECKPOINT_KINDS } from "../../lib/trail.js";

const W = 1000;
const H = 220;
const PAD = { top: 16, right: 12, bottom: 24, left: 44 };

// Elevation vs route-distance. Segment gaps are drawn as a vertical break
// marker (a gap has 0 horizontal width, so a dashed line would be invisible).
// Click adds a checkpoint at the nearest route distance.
export default function ElevationProfile({
  track,
  checkpoints,
  onAddAt,
  onHover,
  hoverCpId,
  onHoverCheckpoint,
  dayRange
}) {
  const svgRef = useRef(null);
  const [hover, setHover] = useState(null);
  const [hoverCp, setHoverCp] = useState(null);

  const setNearCp = (cp) => {
    setHoverCp(cp);
    onHoverCheckpoint?.(cp ? cp.id : null);
  };

  const clearHover = () => {
    setHover(null);
    setNearCp(null);
    onHover?.(null);
  };

  const model = useMemo(() => {
    const cums = buildCumulatives(track.segments);
    const { series, breaks } = buildElevationSeries(
      track.segments,
      cums.cumulativeBySegment,
      cums.segmentOffsets
    );
    let minEle = Infinity;
    let maxEle = -Infinity;
    for (const seg of series)
      for (const [, ele] of seg)
        if (Number.isFinite(ele)) {
          if (ele < minEle) minEle = ele;
          if (ele > maxEle) maxEle = ele;
        }
    const hasEle = Number.isFinite(minEle);
    return { cums, series, breaks, minEle, maxEle, hasEle, totalM: cums.totalM };
  }, [track]);

  const { series, breaks, minEle, maxEle, hasEle, totalM } = model;
  const plotW = W - PAD.left - PAD.right;
  const plotH = H - PAD.top - PAD.bottom;
  const eleSpan = Math.max(1, maxEle - minEle);

  const xOf = (routeM) => PAD.left + (totalM > 0 ? (routeM / totalM) * plotW : 0);
  const yOf = (ele) => PAD.top + plotH - ((ele - minEle) / eleSpan) * plotH;

  // Build per-segment line + area paths, breaking at null elevations.
  const paths = [];
  const areas = [];
  if (hasEle) {
    for (const seg of series) {
      let line = "";
      let area = "";
      let runStart = null;
      const closeArea = (endX) => {
        if (runStart != null) area += ` L ${endX} ${PAD.top + plotH} L ${runStart} ${PAD.top + plotH} Z`;
      };
      for (const [routeM, ele] of seg) {
        if (!Number.isFinite(ele)) {
          if (line) {
            paths.push(line);
            closeArea(xOf(routeM));
            areas.push(area);
          }
          line = "";
          area = "";
          runStart = null;
          continue;
        }
        const x = xOf(routeM);
        const y = yOf(ele);
        if (!line) {
          line = `M ${x} ${y}`;
          area = `M ${x} ${y}`;
          runStart = x;
        } else {
          line += ` L ${x} ${y}`;
          area += ` L ${x} ${y}`;
        }
      }
      if (line) {
        const lastX = xOf(seg[seg.length - 1][0]);
        paths.push(line);
        closeArea(lastX);
        areas.push(area);
      }
    }
  }

  const handleMove = (e) => {
    const rect = svgRef.current.getBoundingClientRect();
    const px = ((e.clientX - rect.left) / rect.width) * W;
    const frac = Math.max(0, Math.min(1, (px - PAD.left) / plotW));
    const routeM = frac * totalM;
    const x = PAD.left + frac * plotW;
    setHover({ routeM, x });
    onHover?.(routeM);
    // Snap a tooltip to the nearest checkpoint marker within ~12 viewBox units.
    let near = null;
    for (const cp of checkpoints) {
      const cx = xOf(cp.anchor.routeDistanceM);
      const d = Math.abs(cx - x);
      if (d <= 12 && (!near || d < near.d)) near = { cp, d, cx };
    }
    if ((near?.cp?.id || null) !== (hoverCp?.id || null)) setNearCp(near ? near.cp : null);
  };

  const hoverEle = (() => {
    if (!hover || !hasEle) return null;
    // nearest sample elevation
    let best = null;
    for (const seg of series)
      for (const [routeM, ele] of seg)
        if (Number.isFinite(ele) && (best == null || Math.abs(routeM - hover.routeM) < best.d))
          best = { d: Math.abs(routeM - hover.routeM), ele };
    return best?.ele ?? null;
  })();

  return (
    <div className="elevation-profile">
      <div className="profile-canvas">
      <svg
        ref={svgRef}
        viewBox={`0 0 ${W} ${H}`}
        role="img"
        aria-label="Elevation profile"
        preserveAspectRatio="none"
        className={hasEle ? "clickable" : ""}
        onMouseMove={hasEle ? handleMove : undefined}
        onMouseLeave={clearHover}
        onClick={() => hasEle && hover && onAddAt(hover.routeM)}
      >
        {!hasEle && (
          <text x={W / 2} y={H / 2} textAnchor="middle" className="profile-empty">
            No elevation data in this track
          </text>
        )}
        {hasEle && (
          <>
            <line x1={PAD.left} y1={PAD.top} x2={PAD.left} y2={PAD.top + plotH} className="axis" />
            <line
              x1={PAD.left}
              y1={PAD.top + plotH}
              x2={W - PAD.right}
              y2={PAD.top + plotH}
              className="axis"
            />
            <text x={PAD.left - 6} y={PAD.top + 4} textAnchor="end" className="axis-label">
              {Math.round(maxEle)}
            </text>
            <text x={PAD.left - 6} y={PAD.top + plotH} textAnchor="end" className="axis-label">
              {Math.round(minEle)}
            </text>
            {areas.map((d, i) => (
              <path key={`a${i}`} d={d} className="profile-area" />
            ))}
            {paths.map((d, i) => (
              <path key={`l${i}`} d={d} className="profile-line" />
            ))}
          </>
        )}

        {/* Selected-day band: dim everything outside the day's stretch */}
        {dayRange && (
          <g className="profile-day-mask">
            <rect
              x={PAD.left}
              y={PAD.top}
              width={Math.max(0, xOf(dayRange.startRouteM) - PAD.left)}
              height={plotH}
            />
            <rect
              x={xOf(dayRange.endRouteM)}
              y={PAD.top}
              width={Math.max(0, W - PAD.right - xOf(dayRange.endRouteM))}
              height={plotH}
            />
          </g>
        )}

        {/* Segment break markers */}
        {breaks.map((routeM, i) => (
          <line
            key={`b${i}`}
            x1={xOf(routeM)}
            y1={PAD.top}
            x2={xOf(routeM)}
            y2={PAD.top + plotH}
            className="profile-break"
          />
        ))}

        {/* Checkpoint markers */}
        {checkpoints.map((cp) => {
          const x = xOf(cp.anchor.routeDistanceM);
          const active = (hoverCpId || hoverCp?.id) === cp.id;
          const outside =
            dayRange &&
            (cp.anchor.routeDistanceM < dayRange.startRouteM - 1 ||
              cp.anchor.routeDistanceM > dayRange.endRouteM + 1);
          return (
            <g key={cp.id} className={`profile-cp${active ? " active" : ""}${outside ? " dim" : ""}`}>
              <line x1={x} y1={PAD.top} x2={x} y2={PAD.top + plotH} className="cp-line" />
              <circle
                cx={x}
                cy={hasEle && cp.anchor.ele != null ? yOf(cp.anchor.ele) : PAD.top + 6}
                r={active ? 6 : 4}
                className={`cp-dot kind-${cp.kind || "poi"}${cp.kind === "overnight" ? " overnight" : ""}`}
              />
            </g>
          );
        })}

        {hover && (
          <line
            x1={hover.x}
            y1={PAD.top}
            x2={hover.x}
            y2={PAD.top + plotH}
            className="profile-hover"
          />
        )}
      </svg>
      {hoverCp && (
        <div
          className={`cp-tip profile-cp-tip kind-${hoverCp.kind || "poi"}`}
          style={{
            left: `${(xOf(hoverCp.anchor.routeDistanceM) / W) * 100}%`,
            top: `${((hasEle && hoverCp.anchor.ele != null ? yOf(hoverCp.anchor.ele) : PAD.top + 6) / H) * 100}%`
          }}
        >
          <span className="cp-tip-name">
            {(CHECKPOINT_KINDS[hoverCp.kind] || CHECKPOINT_KINDS.poi).emoji}{" "}
            {hoverCp.name || (CHECKPOINT_KINDS[hoverCp.kind] || CHECKPOINT_KINDS.poi).label}
          </span>
          {hoverCp.note && <span className="cp-tip-note">{hoverCp.note}</span>}
          <span className="cp-tip-meta">
            {(hoverCp.anchor.routeDistanceM / 1000).toFixed(2)} km
            {hoverCp.anchor.ele != null && ` · ${hoverCp.anchor.ele} m`}
          </span>
        </div>
      )}
      </div>
      <div className="profile-caption">
        {!hasEle
          ? "No elevation data in this GPX — add checkpoints on the map or by distance below."
          : hover
            ? `${(hover.routeM / 1000).toFixed(2)} km${hoverEle != null ? ` · ${Math.round(hoverEle)} m` : ""} — click to add checkpoint`
            : "Click the profile to add a checkpoint"}
      </div>
    </div>
  );
}
