import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { buildCumulatives, buildElevationSeries, CHECKPOINT_KINDS } from "../../lib/trail.js";
import AddPointConfirm from "./AddPointConfirm.jsx";
import { PinPlusIcon, MaximizeIcon, MinimizeIcon } from "../../components/icons.jsx";

// The viewBox tracks the element's real pixel size, so one user unit is one CSS
// pixel: labels render at their true size (a fixed 1000-unit box squeezed a
// phone's 390px width down to ~4px text) and nothing stretches when the box is
// a different shape — which is what makes the full-screen mode useful.
const FALLBACK = { w: 1000, h: 264 };
// `bottom` is only a hairline of breathing room: the distance read-out hangs
// past it on purpose (the svg is allowed to overflow) rather than reserving
// dead space for it.
const PAD = { top: 16, right: 12, bottom: 8, left: 44 };

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
  dayRange,
  dayBands
}) {
  const svgRef = useRef(null);
  const canvasRef = useRef(null);
  const [hover, setHover] = useState(null);
  const [hoverCp, setHoverCp] = useState(null);
  const [pending, setPending] = useState(null); // { routeM, left, top } confirm popover
  // Off by default so a tap (phones have no hover) reads out km/elevation
  // instead of always starting a new checkpoint.
  const [addMode, setAddMode] = useState(false);
  const [full, setFull] = useState(false);
  const [box, setBox] = useState(FALLBACK);

  // Keep the drawing coordinates in step with the element's real size.
  useLayoutEffect(() => {
    const el = canvasRef.current;
    if (!el) return;
    const measure = () => {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) {
        setBox((prev) =>
          Math.abs(prev.w - r.width) < 0.5 && Math.abs(prev.h - r.height) < 0.5
            ? prev
            : { w: r.width, h: r.height }
        );
      }
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Full screen: lock page scroll, leave on Escape (mirrors the map).
  useEffect(() => {
    if (!full) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    const onKey = (e) => e.key === "Escape" && setFull(false);
    window.addEventListener("keydown", onKey);
    return () => {
      document.body.style.overflow = prev;
      window.removeEventListener("keydown", onKey);
    };
  }, [full]);

  const W = box.w;
  const H = box.h;

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

  // Build line + area paths. When day bands are known each path is clipped to a
  // day's route range so the profile is coloured the same way as the map.
  // Memoised: a full-resolution track times the day bands is far too much work
  // to redo on every hover frame.
  const strokes = useMemo(() => {
    const bands =
      dayBands && dayBands.length > 1
        ? dayBands
        : [{ startRouteM: -1, endRouteM: Infinity, color: null }];
    const out = []; // { line, area, color }
    if (!hasEle) return out;
    for (const band of bands) {
      for (const seg of series) {
        let line = "";
        let area = "";
        let runStart = null;
        const flush = (endX) => {
          if (line) {
            if (runStart != null) area += ` L ${endX} ${PAD.top + plotH} L ${runStart} ${PAD.top + plotH} Z`;
            out.push({ line, area, color: band.color });
          }
          line = "";
          area = "";
          runStart = null;
        };
        for (const [routeM, ele] of seg) {
          const inBand = routeM >= band.startRouteM && routeM <= band.endRouteM;
          if (!Number.isFinite(ele) || !inBand) {
            flush(xOf(routeM));
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
        flush(xOf(seg[seg.length - 1][0]));
      }
    }
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [series, dayBands, hasEle, W, H, minEle, maxEle, totalM]);

  const moveToClientX = (clientX) => {
    const rect = svgRef.current.getBoundingClientRect();
    const px = ((clientX - rect.left) / rect.width) * W;
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

  const handleMove = (e) => moveToClientX(e.clientX);
  // Touch has no hover: dragging (or tapping) scrubs the read-out. Not
  // preventDefault-ed, so the page still scrolls normally.
  const handleTouch = (e) => {
    const touch = e.touches?.[0];
    if (touch) moveToClientX(touch.clientX);
  };

  // With add-mode on, clicking opens the same "Add a checkpoint here?" confirm
  // as the map. With it off (the default) the plot is read-only.
  const handleClick = (e) => {
    if (!addMode || !hasEle || !hover) return;
    const rect = canvasRef.current.getBoundingClientRect();
    setPending({ routeM: hover.routeM, left: e.clientX - rect.left, top: e.clientY - rect.top });
  };

  // Keep the distance pill inside the plot even at the very ends.
  const readoutX = hover ? Math.min(Math.max(hover.x, PAD.left + 27), W - PAD.right - 27) : 0;

  // Checkpoint tooltip anchor; near the top of the plot it flips below the dot
  // so it can't escape the panel (see `.profile-cp-tip.flip`).
  const cpTipY = hoverCp
    ? hasEle && hoverCp.anchor.ele != null
      ? yOf(hoverCp.anchor.ele)
      : PAD.top + 6
    : 0;

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
    <div className={`elevation-profile ${full ? "fullscreen" : ""}`}>
      <div className="profile-tools">
      {hasEle && (
        <button
          type="button"
          className={`profile-add-toggle ${addMode ? "active" : ""}`}
          title={
            addMode
              ? "Add-checkpoint mode on — click the profile to add one"
              : "Turn on add-checkpoint mode (off: the profile only reads out km / elevation)"
          }
          aria-label="Add checkpoints from the profile"
          aria-pressed={addMode}
          onClick={() => {
            setAddMode((v) => !v);
            setPending(null);
          }}
        >
          <PinPlusIcon size={15} />
        </button>
      )}
        <button
          type="button"
          className="profile-add-toggle"
          title={full ? "Exit full screen (Esc)" : "Full screen"}
          aria-label={full ? "Exit full screen" : "Full screen"}
          aria-pressed={full}
          onClick={() => {
            setFull((v) => !v);
            setPending(null);
          }}
        >
          {full ? <MinimizeIcon size={15} /> : <MaximizeIcon size={15} />}
        </button>
      </div>
      {full && <span className="profile-rotate-hint">Rotate your phone for a wider profile</span>}
      <div className="profile-canvas" ref={canvasRef}>
      <svg
        ref={svgRef}
        viewBox={`0 0 ${W} ${H}`}
        role="img"
        aria-label="Elevation profile"
        preserveAspectRatio="none"
        className={hasEle && addMode ? "clickable" : ""}
        onMouseMove={hasEle ? handleMove : undefined}
        onMouseLeave={clearHover}
        onTouchStart={hasEle ? handleTouch : undefined}
        onTouchMove={hasEle ? handleTouch : undefined}
        onClick={handleClick}
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
            <text
              x={PAD.left - 6}
              y={PAD.top + 4}
              textAnchor="end"
              className={`axis-label${hover ? " muted" : ""}`}
            >
              {Math.round(maxEle)}
            </text>
            <text
              x={PAD.left - 6}
              y={PAD.top + plotH}
              textAnchor="end"
              className={`axis-label${hover ? " muted" : ""}`}
            >
              {Math.round(minEle)}
            </text>
            {strokes.map((st, i) => (
              <path
                key={`a${i}`}
                d={st.area}
                className="profile-area"
                style={st.color ? { fill: st.color, fillOpacity: 0.18 } : undefined}
              />
            ))}
            {strokes.map((st, i) => (
              <path
                key={`l${i}`}
                d={st.line}
                className="profile-line"
                style={st.color ? { stroke: st.color } : undefined}
              />
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

        {/* Hover read-outs live on the axes rather than in a caption line: the
            elevation sits in the left axis gutter, level with the point; the
            distance sits under the point on the x axis. */}
        {hover && hasEle && hoverEle != null && (
          <g className="profile-readout">
            <rect x={3} y={yOf(hoverEle) - 8} width={PAD.left - 9} height={16} rx={4} />
            <text x={PAD.left - 9} y={yOf(hoverEle)} textAnchor="end" dominantBaseline="central">
              {Math.round(hoverEle)}
            </text>
          </g>
        )}
        {hover && (
          <g className="profile-readout">
            <rect x={readoutX - 27} y={PAD.top + plotH + 4} width={54} height={16} rx={4} />
            <text x={readoutX} y={PAD.top + plotH + 12} textAnchor="middle" dominantBaseline="central">
              {(hover.routeM / 1000).toFixed(2)} km
            </text>
          </g>
        )}
      </svg>
      {hoverCp && (
        <div
          className={`cp-tip profile-cp-tip kind-${hoverCp.kind || "poi"}${
            cpTipY < H * 0.3 ? " flip" : ""
          }`}
          style={{ left: xOf(hoverCp.anchor.routeDistanceM), top: cpTipY }}
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
      {pending && (
        <AddPointConfirm
          left={pending.left}
          top={pending.top}
          onAdd={() => {
            onAddAt(pending.routeM);
            setPending(null);
          }}
          onCancel={() => setPending(null)}
        />
      )}
      </div>
    </div>
  );
}
