import React, { useMemo, useRef } from "react";
import {
  projectTrack,
  decimateForRender,
  detectAntimeridian,
  buildCumulatives,
  sliceSegments,
  CHECKPOINT_KINDS
} from "../../lib/trail.js";

// Large working space; the viewBox is then cropped tight to the track so it
// fills the panel (contain) regardless of portrait/landscape orientation.
const SPACE = 1000;

// Endpoint icon geometry (24×24 viewBox, matching the legend + map pins).
const WHISTLE = (
  <>
    <circle cx="8.5" cy="14" r="5.5" />
    <path d="M13.5 10.5H20a1 1 0 0 1 1 1v1.5a1 1 0 0 1-1 1h-1.5" />
    <path d="M8.5 8.5V5.5" />
  </>
);
const FLAG = (
  <>
    <path d="M5 21V4" />
    <path d="M5 4h11l-2.2 4L16 12H5" />
  </>
);
const ICON_STROKE = { fill: "none", stroke: "#fff", strokeWidth: 2.4, strokeLinecap: "round", strokeLinejoin: "round" };

// A start / finish / combined (loop) endpoint: a coloured disc (or pill) with a
// white line-icon, mirroring the real map's markers.
function ShapeEndpoint({ x, y, kind, r, name }) {
  if (kind === "combo") {
    const w = r * 3.6;
    const h = r * 2.1;
    const s = (h * 0.62) / 24;
    const place = (cx) => `translate(${cx - 12 * s} ${y - 12 * s}) scale(${s})`;
    return (
      <g className="track-endpoint">
        <title>{`${name} · loop`}</title>
        <rect x={x - w / 2} y={y - h / 2} width={w} height={h} rx={h / 2} fill="#1b5e3f" stroke="#fff" strokeWidth={h * 0.06} />
        <g transform={place(x - w * 0.23)} {...ICON_STROKE}>{WHISTLE}</g>
        <g transform={place(x + w * 0.23)} {...ICON_STROKE}>{FLAG}</g>
      </g>
    );
  }
  const s = (r * 1.5) / 24;
  const fill = kind === "start" ? "#2e9e5b" : "#b42318";
  return (
    <g className="track-endpoint">
      <title>{name}</title>
      <circle cx={x} cy={y} r={r} fill={fill} stroke="#fff" strokeWidth={r * 0.16} />
      <g transform={`translate(${x - 12 * s} ${y - 12 * s}) scale(${s})`} {...ICON_STROKE}>
        {kind === "start" ? WHISTLE : FLAG}
      </g>
    </g>
  );
}

// 2D top-down shape of the track (one sub-path per segment). Click adds a
// checkpoint at the nearest point on the track. Shares the map's visual model:
// per-day colours, whistle/flag endpoints and hover-linked checkpoints.
// `highlight` (a {lat,lng}) draws a moving marker linked to the elevation
// profile. Hidden with a notice when the track crosses the antimeridian.
export default function TrackShape({
  track,
  checkpoints,
  onAddAt,
  highlight,
  hoverCpId,
  onHoverCheckpoint,
  dayRange,
  dayBands,
  startName,
  finishName,
  loop
}) {
  const svgRef = useRef(null);
  const antimeridian = useMemo(() => detectAntimeridian(track.segments), [track]);
  const cums = useMemo(() => buildCumulatives(track.segments), [track]);

  const model = useMemo(() => {
    if (antimeridian) return null;
    const thin = decimateForRender(track.segments, 1500);
    const proj = projectTrack(thin, SPACE, SPACE, 0);
    // Tight bounding box of the drawn points → crop the viewBox to it.
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const seg of proj.paths)
      for (const [x, y] of seg) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    const unit = Math.max(maxX - minX, maxY - minY) || SPACE;
    const pad = unit * 0.06;
    return {
      ...proj,
      viewBox: `${minX - pad} ${minY - pad} ${maxX - minX + 2 * pad} ${maxY - minY + 2 * pad}`,
      unit
    };
  }, [track, antimeridian]);

  if (antimeridian) {
    return (
      <div className="track-shape antimeridian">
        <p>Map preview unavailable for tracks that cross the antimeridian.</p>
      </div>
    );
  }

  const { paths, project, unproject, viewBox, unit } = model;
  const start = paths[0]?.[0];
  const lastSeg = paths[paths.length - 1];
  const end = lastSeg?.[lastSeg.length - 1];
  const stroke = unit * 0.006;
  const rEnd = unit * 0.022;
  const rCp = unit * 0.013;
  const banded = dayBands && dayBands.length > 1;

  const handleClick = (e) => {
    if (!onAddAt) return;
    // getScreenCTM maps screen px → user coords correctly through the viewBox
    // crop + preserveAspectRatio letterboxing.
    const ctm = svgRef.current.getScreenCTM();
    if (!ctm) return;
    const pt = svgRef.current.createSVGPoint();
    pt.x = e.clientX;
    pt.y = e.clientY;
    const u = pt.matrixTransform(ctm.inverse());
    const [lat, lng] = unproject(u.x, u.y);
    onAddAt(lat, lng);
  };

  const hi = highlight ? project(highlight.lat, highlight.lng) : null;

  return (
    <div className="track-shape">
      <svg
        ref={svgRef}
        viewBox={viewBox}
        preserveAspectRatio="xMidYMid meet"
        role="img"
        aria-label="Track shape"
        className={onAddAt ? "clickable" : ""}
        onClick={handleClick}
      >
        {/* Track — coloured per itinerary day when there are ≥2 days, else one
            accent line. Dimmed while a single day/range is isolated. */}
        {banded
          ? dayBands.map((band, bi) =>
              sliceSegments(track.segments, cums, band.startRouteM, band.endRouteM).map((seg, si) => (
                <polyline
                  key={`b${bi}-${si}`}
                  points={seg.points.map(([lat, lng]) => project(lat, lng).join(",")).join(" ")}
                  className={`track-line${dayRange ? " dimmed" : ""}`}
                  style={{ strokeWidth: stroke, stroke: band.color }}
                />
              ))
            )
          : paths.map((pts, i) => (
              <polyline
                key={i}
                points={pts.map(([x, y]) => `${x},${y}`).join(" ")}
                className={`track-line${dayRange ? " dimmed" : ""}`}
                style={{ strokeWidth: stroke }}
              />
            ))}
        {dayRange &&
          sliceSegments(track.segments, cums, dayRange.startRouteM, dayRange.endRouteM).map((seg, i) => (
            <polyline
              key={`d${i}`}
              points={seg.points.map(([lat, lng]) => project(lat, lng).join(",")).join(" ")}
              className="track-line day"
              style={{ strokeWidth: stroke * 1.6 }}
            />
          ))}
        {checkpoints.map((cp) => {
          const [x, y] = project(cp.anchor.lat, cp.anchor.lng);
          const active = hoverCpId === cp.id;
          const outside =
            dayRange &&
            (cp.anchor.routeDistanceM < dayRange.startRouteM - 1 ||
              cp.anchor.routeDistanceM > dayRange.endRouteM + 1);
          const kind = CHECKPOINT_KINDS[cp.kind] ? cp.kind : "poi";
          const label = cp.name || CHECKPOINT_KINDS[kind].label;
          return (
            <circle
              key={cp.id}
              cx={x}
              cy={y}
              r={active ? rCp * 1.8 : rCp}
              className={`track-cp kind-${kind}${cp.kind === "overnight" ? " overnight" : ""}${
                active ? " active" : ""
              }${outside ? " dim" : ""}`}
              onMouseEnter={() => onHoverCheckpoint?.(cp.id)}
              onMouseLeave={() => onHoverCheckpoint?.(null)}
            >
              <title>{cp.note ? `${label} — ${cp.note}` : label}</title>
            </circle>
          );
        })}
        {/* Endpoints last so they sit above the track + checkpoints. */}
        {loop && start ? (
          <ShapeEndpoint x={start[0]} y={start[1]} kind="combo" r={rEnd} name={startName || "Start / Finish"} />
        ) : (
          <>
            {start && <ShapeEndpoint x={start[0]} y={start[1]} kind="start" r={rEnd} name={startName || "Start"} />}
            {end && <ShapeEndpoint x={end[0]} y={end[1]} kind="finish" r={rEnd} name={finishName || "Finish"} />}
          </>
        )}
        {hi && (
          <g className="track-hover">
            <circle cx={hi[0]} cy={hi[1]} r={unit * 0.024} className="track-hover-halo" />
            <circle cx={hi[0]} cy={hi[1]} r={unit * 0.013} className="track-hover-dot" style={{ strokeWidth: stroke }} />
          </g>
        )}
      </svg>
    </div>
  );
}
