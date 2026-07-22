import React, { useMemo } from "react";
import { projectTrack, decimateForRender, detectAntimeridian } from "../../lib/trail.js";

const W = 400;
const H = 320;

// 2D top-down shape of the track (one sub-path per segment). Hidden with a
// notice when the track crosses the antimeridian (deferred to a later phase).
export default function TrackShape({ track, checkpoints }) {
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

  const { paths, project } = model;
  const start = paths[0]?.[0];
  const lastSeg = paths[paths.length - 1];
  const end = lastSeg?.[lastSeg.length - 1];

  return (
    <div className="track-shape">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Track shape">
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
      </div>
    </div>
  );
}
