import React, { useEffect, useRef, useState } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { CHECKPOINT_KINDS } from "../../lib/trail.js";

const ACCENT = "#1b5e3f";
const GREEN = "#2e9e5b";
const RED = "#b42318";

const isMac = typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform || "");
const ZOOM_KEY_LABEL = isMac ? "⌘" : "Ctrl";

// Escape user-supplied text before it goes into a Leaflet tooltip (HTML string).
function esc(s) {
  return String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]
  );
}

// Real basemap (OpenStreetMap tiles) with the track drawn on top. Uses vector
// CircleMarkers only — no marker image assets — so it stays within the app's
// locked-down CSP (the tile origin is allow-listed in vite.config.js). Falls
// back to the SVG TrackShape via the parent when the user prefers it / offline.
export default function TrackMap({ track, checkpoints, onAddAt, highlight, hoverCpId, onHoverCheckpoint }) {
  const elRef = useRef(null);
  const mapRef = useRef(null);
  const trackLayer = useRef(null);
  const cpLayer = useRef(null);
  const cpMarkers = useRef(new Map()); // checkpoint id -> Leaflet marker
  const hoverMarker = useRef(null);
  const onAddRef = useRef(onAddAt);
  onAddRef.current = onAddAt;
  const onHoverCpRef = useRef(onHoverCheckpoint);
  onHoverCpRef.current = onHoverCheckpoint;
  const [scrollHint, setScrollHint] = useState(false);
  const hintTimer = useRef(null);

  // Init the map once.
  useEffect(() => {
    const map = L.map(elRef.current, {
      zoomControl: true,
      attributionControl: true,
      // Plain wheel must scroll the PAGE, not the map (see the wheel handler
      // below, which zooms only with Ctrl/⌘ — and with trackpad pinch, which
      // browsers deliver as a ctrlKey wheel event).
      scrollWheelZoom: false,
      // zoomSnap 0 = fully fractional zoom. Anything > 0 quantises the small
      // deltas a trackpad pinch produces, so they'd round away to nothing.
      zoomSnap: 0,
      zoomDelta: 0.5
    });
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 17,
      attribution: "© OpenStreetMap contributors"
    }).addTo(map);
    map.on("click", (e) => onAddRef.current?.(e.latlng.lat, e.latlng.lng));
    mapRef.current = map;

    const el = elRef.current;
    const onWheel = (e) => {
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        // A trackpad pinch emits many small deltas; a mouse wheel emits few big
        // ones. Scale each so both feel gentle rather than jumping a whole level.
        const fine = Math.abs(e.deltaY) < 25;
        const next = map.getZoom() - e.deltaY / (fine ? 40 : 240);
        map.setZoom(Math.max(map.getMinZoom(), Math.min(map.getMaxZoom(), next)), { animate: false });
        setScrollHint(false);
        return;
      }
      // Let the page scroll, but tell the user how to zoom.
      setScrollHint(true);
      clearTimeout(hintTimer.current);
      hintTimer.current = setTimeout(() => setScrollHint(false), 1400);
    };
    el.addEventListener("wheel", onWheel, { passive: false });

    // The container starts at its final size, but guard against a 0-size init.
    setTimeout(() => map.invalidateSize(), 0);
    return () => {
      el.removeEventListener("wheel", onWheel);
      clearTimeout(hintTimer.current);
      map.remove();
      mapRef.current = null;
    };
  }, []);

  // Draw the track (one polyline per segment) and fit the view.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (trackLayer.current) trackLayer.current.remove();
    const group = L.featureGroup();
    for (const seg of track.segments) {
      L.polyline(seg.points.map((p) => [p[0], p[1]]), { color: ACCENT, weight: 4, opacity: 0.9 }).addTo(group);
    }
    const first = track.segments[0]?.points[0];
    const lastSeg = track.segments[track.segments.length - 1]?.points;
    const last = lastSeg?.[lastSeg.length - 1];
    if (first) L.circleMarker([first[0], first[1]], { radius: 6, color: "#fff", weight: 2, fillColor: GREEN, fillOpacity: 1 }).addTo(group);
    if (last) L.circleMarker([last[0], last[1]], { radius: 6, color: "#fff", weight: 2, fillColor: RED, fillOpacity: 1 }).addTo(group);
    group.addTo(map);
    trackLayer.current = group;
    const bounds = group.getBounds();
    if (bounds.isValid()) map.fitBounds(bounds, { padding: [24, 24] });
  }, [track]);

  // Checkpoint markers.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (cpLayer.current) cpLayer.current.remove();
    cpMarkers.current.clear();
    const group = L.featureGroup();
    for (const cp of checkpoints) {
      const kind = CHECKPOINT_KINDS[cp.kind] ? cp.kind : "poi";
      const emoji = CHECKPOINT_KINDS[kind].emoji;
      const icon = L.divIcon({
        className: `cp-marker kind-${kind}`,
        html: `<span class="cp-marker-pin">${emoji}</span>`,
        iconSize: [28, 28],
        iconAnchor: [14, 14],
        tooltipAnchor: [0, -16]
      });
      const title = esc(cp.name || CHECKPOINT_KINDS[kind].label);
      const note = cp.note ? `<span class="cp-tip-note">${esc(cp.note)}</span>` : "";
      const marker = L.marker([cp.anchor.lat, cp.anchor.lng], { icon })
        .bindTooltip(`<span class="cp-tip-name">${emoji} ${title}</span>${note}`, {
          direction: "top",
          className: "cp-tip"
        })
        .addTo(group);
      marker.on("mouseover", () => onHoverCpRef.current?.(cp.id));
      marker.on("mouseout", () => onHoverCpRef.current?.(null));
      cpMarkers.current.set(cp.id, marker);
    }
    group.addTo(map);
    cpLayer.current = group;
  }, [checkpoints]);

  // Enlarge/highlight the marker for the checkpoint hovered anywhere (map or
  // elevation profile).
  useEffect(() => {
    for (const [cpId, marker] of cpMarkers.current) {
      const el = marker.getElement?.();
      if (!el) continue;
      el.classList.toggle("cp-marker-active", cpId === hoverCpId);
      if (cpId === hoverCpId) marker.setZIndexOffset(1000);
      else marker.setZIndexOffset(0);
    }
  }, [hoverCpId, checkpoints]);

  // Hover highlight linked to the elevation profile.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (!highlight) {
      if (hoverMarker.current) {
        hoverMarker.current.remove();
        hoverMarker.current = null;
      }
      return;
    }
    const latlng = [highlight.lat, highlight.lng];
    if (!hoverMarker.current) {
      hoverMarker.current = L.circleMarker(latlng, {
        radius: 7,
        color: ACCENT,
        weight: 3,
        fillColor: "#fff",
        fillOpacity: 1
      }).addTo(map);
    } else {
      hoverMarker.current.setLatLng(latlng);
    }
  }, [highlight]);

  return (
    <div className="track-map">
      <div ref={elRef} className="track-map-canvas" />
      {scrollHint && (
        <div className="map-scroll-hint">Use {ZOOM_KEY_LABEL} + scroll (or pinch) to zoom the map</div>
      )}
      <div className="track-legend">
        <span className="dot start" /> Start
        <span className="dot end" /> Finish
        {onAddAt && <span className="track-hint">· click the map to add a checkpoint</span>}
      </div>
    </div>
  );
}
