import React, { useMemo, useRef } from "react";
import { projectTrack, decimateForRender, detectAntimeridian } from "../../lib/trail.js";

const W = 400;
const H = 320;

// 2D top-down shape of the track (one sub-path per segment). Click adds a
// checkpoint at the nearest point on the track — the primary way to place
// checkpoints on a track that has no elevation profile. Hidden with a notice
// when the track crosses the antimeridian (deferred to a later phase).
export default function TrackShape({ track, checkpoints, onAddAt }) {
  const svgRef = useRef(null);
  const antimeridian = useMemo(() => detectAntimeridian(track.segments), [track]);

  const model = useMemo(() => {
    if (antimeridian) return null;
    const thin = decimateForRender(track.segments, 1500);
    return projectTrack(thin, W, H, 10);
  }, [track, antimeridian]);

  if (antimeridian) {
    return (
      <div className="track-shape antimeridian">
        <p>Map preview unavailable for tracks that cross the antimeridian.</p>
      </div>
    );
  }

  const { paths, project, unproject } = model;
  const start = paths[0]?.[0];
  const lastSeg = paths[paths.length - 1];
  const end = lastSeg?.[lastSeg.length - 1];

  const handleClick = (e) => {
    if (!onAddAt) return;
    const rect = svgRef.current.getBoundingClientRect();
    const x = ((e.clientX - rect.left) / rect.width) * W;
    const y = ((e.clientY - rect.top) / rect.height) * H;
    const [lat, lng] = unproject(x, y);
    onAddAt(lat, lng);
  };

  return (
    <div className="track-shape">
      <svg
        ref={svgRef}
        viewBox={`0 0 ${W} ${H}`}
        role="img"
        aria-label="Track shape"
        className={onAddAt ? "clickable" : ""}
        onClick={handleClick}
      >
        {paths.map((pts, i) => (
          <polyline
            key={i}
            points={pts.map(([x, y]) => `${x},${y}`).join(" ")}
            className="track-line"
          />
        ))}
        {start && <circle cx={start[0]} cy={start[1]} r={5} className="track-start" />}
        {end && <circle cx={end[0]} cy={end[1]} r={5} className="track-end" />}
        {checkpoints.map((cp) => {
          const [x, y] = project(cp.anchor.lat, cp.anchor.lng);
          return <circle key={cp.id} cx={x} cy={y} r={4} className={cp.overnight ? "track-cp overnight" : "track-cp"} />;
        })}
      </svg>
      <div className="track-legend">
        <span className="dot start" /> Start
        <span className="dot end" /> Finish
        {onAddAt && <span className="track-hint">· click the track to add a checkpoint</span>}
      </div>
    </div>
  );
}
