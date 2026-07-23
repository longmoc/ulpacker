import React, { useMemo, useRef } from "react";
import { projectTrack, decimateForRender, detectAntimeridian, buildCumulatives, sliceSegments } from "../../lib/trail.js";

// Large working space; the viewBox is then cropped tight to the track so it
// fills the panel (contain) regardless of portrait/landscape orientation.
const SPACE = 1000;

// 2D top-down shape of the track (one sub-path per segment). Click adds a
// checkpoint at the nearest point on the track. `highlight` (a {lat,lng}) draws
// a moving marker linked to the elevation-profile hover. Hidden with a notice
// when the track crosses the antimeridian (deferred to a later phase).
export default function TrackShape({ track, checkpoints, onAddAt, highlight, hoverCpId, dayRange }) {
  const svgRef = useRef(null);
  const antimeridian = useMemo(() => detectAntimeridian(track.segments), [track]);

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
  const rStartEnd = unit * 0.016;
  const rCp = unit * 0.013;

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
        {paths.map((pts, i) => (
          <polyline
            key={i}
            points={pts.map(([x, y]) => `${x},${y}`).join(" ")}
            className={`track-line${dayRange ? " dimmed" : ""}`}
            style={{ strokeWidth: stroke }}
          />
        ))}
        {dayRange &&
          sliceSegments(track.segments, buildCumulatives(track.segments), dayRange.startRouteM, dayRange.endRouteM).map(
            (seg, i) => (
              <polyline
                key={`d${i}`}
                points={seg.points.map(([lat, lng]) => project(lat, lng).join(",")).join(" ")}
                className="track-line day"
                style={{ strokeWidth: stroke * 1.6 }}
              />
            )
          )}
        {start && <circle cx={start[0]} cy={start[1]} r={rStartEnd} className="track-start" />}
        {end && <circle cx={end[0]} cy={end[1]} r={rStartEnd} className="track-end" />}
        {checkpoints.map((cp) => {
          const [x, y] = project(cp.anchor.lat, cp.anchor.lng);
          const active = hoverCpId === cp.id;
          const outside =
            dayRange &&
            (cp.anchor.routeDistanceM < dayRange.startRouteM - 1 ||
              cp.anchor.routeDistanceM > dayRange.endRouteM + 1);
          return (
            <circle
              key={cp.id}
              cx={x}
              cy={y}
              r={active ? rCp * 1.8 : rCp}
              className={`track-cp kind-${cp.kind || "poi"}${cp.kind === "overnight" ? " overnight" : ""}${
                active ? " active" : ""
              }${outside ? " dim" : ""}`}
            />
          );
        })}
        {hi && (
          <g className="track-hover">
            <circle cx={hi[0]} cy={hi[1]} r={unit * 0.024} className="track-hover-halo" />
            <circle cx={hi[0]} cy={hi[1]} r={unit * 0.013} className="track-hover-dot" style={{ strokeWidth: stroke }} />
          </g>
        )}
      </svg>
      <div className="track-legend">
        <span className="dot start" /> Start
        <span className="dot end" /> Finish
        {onAddAt && <span className="track-hint">· click the track to add a checkpoint</span>}
      </div>
    </div>
  );
}
