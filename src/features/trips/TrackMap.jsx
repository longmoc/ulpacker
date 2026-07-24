import React, { useEffect, useRef, useState } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { CHECKPOINT_KINDS, buildCumulatives, sliceSegments } from "../../lib/trail.js";

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
export default function TrackMap({
  track,
  checkpoints,
  onAddAt,
  highlight,
  hoverCpId,
  onHoverCheckpoint,
  dayRange,
  dayBands,
  startName,
  finishName
}) {
  const elRef = useRef(null);
  const mapRef = useRef(null);
  const trackLayer = useRef(null);
  const cpLayer = useRef(null);
  const cpMarkers = useRef(new Map()); // checkpoint id -> Leaflet marker
  const dayLayer = useRef(null);
  const hoverMarker = useRef(null);
  const onAddRef = useRef(onAddAt);
  onAddRef.current = onAddAt;
  const onHoverCpRef = useRef(onHoverCheckpoint);
  onHoverCpRef.current = onHoverCheckpoint;
  const startNameRef = useRef(startName);
  startNameRef.current = startName;
  const finishNameRef = useRef(finishName);
  finishNameRef.current = finishName;
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
    // A stray map click shouldn't create a checkpoint — ask first.
    map.on("click", (e) => {
      if (!onAddRef.current) return;
      const box = document.createElement("div");
      box.className = "map-confirm";
      const label = document.createElement("span");
      label.textContent = "Add a checkpoint here?";
      const actions = document.createElement("div");
      actions.className = "map-confirm-actions";
      const add = document.createElement("button");
      add.type = "button";
      add.className = "primary";
      add.textContent = "Add";
      const cancel = document.createElement("button");
      cancel.type = "button";
      cancel.textContent = "Cancel";
      actions.append(add, cancel);
      box.append(label, actions);
      const popup = L.popup({ closeButton: false, className: "map-confirm-popup", offset: [0, -6] })
        .setLatLng(e.latlng)
        .setContent(box)
        .openOn(map);
      add.addEventListener("click", () => {
        map.closePopup(popup);
        onAddRef.current?.(e.latlng.lat, e.latlng.lng);
      });
      cancel.addEventListener("click", () => map.closePopup(popup));
    });
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
    const cums = buildCumulatives(track.segments);
    // White casing under every stroke keeps the colours legible over any tile.
    const draw = (segs, color) => {
      for (const seg of segs) {
        const latlngs = seg.points.map((p) => [p[0], p[1]]);
        L.polyline(latlngs, { color: "#fff", weight: 8, opacity: 0.9 }).addTo(group);
        L.polyline(latlngs, { color, weight: 4, opacity: 1 }).addTo(group);
      }
    };
    if (dayBands && dayBands.length > 1) {
      for (const band of dayBands) {
        draw(sliceSegments(track.segments, cums, band.startRouteM, band.endRouteM), band.color);
      }
    } else {
      draw(track.segments, ACCENT);
    }
    const first = track.segments[0]?.points[0];
    const lastSeg = track.segments[track.segments.length - 1]?.points;
    const last = lastSeg?.[lastSeg.length - 1];
    if (first)
      L.circleMarker([first[0], first[1]], { radius: 6, color: "#fff", weight: 2, fillColor: GREEN, fillOpacity: 1 })
        .bindTooltip(`🚩 ${esc(startNameRef.current || "Start")}`, { direction: "top", className: "cp-tip" })
        .addTo(group);
    if (last)
      L.circleMarker([last[0], last[1]], { radius: 6, color: "#fff", weight: 2, fillColor: RED, fillOpacity: 1 })
        .bindTooltip(`🏁 ${esc(finishNameRef.current || "Finish")}`, { direction: "top", className: "cp-tip" })
        .addTo(group);
    group.addTo(map);
    trackLayer.current = group;
    const bounds = group.getBounds();
    if (bounds.isValid()) map.fitBounds(bounds, { padding: [24, 24] });
  }, [track, dayBands, startName, finishName]);

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

  // Selecting a day dims the whole trail and overlays that day's stretch.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    if (dayLayer.current) {
      dayLayer.current.remove();
      dayLayer.current = null;
    }
    if (trackLayer.current) {
      trackLayer.current.eachLayer((l) => {
        // polylines only (circleMarkers have getLatLng, not getLatLngs)
        if (l.setStyle && l.getLatLngs) l.setStyle({ opacity: dayRange ? 0.22 : 0.9 });
      });
    }
    if (!dayRange) return;
    const cums = buildCumulatives(track.segments);
    const slices = sliceSegments(track.segments, cums, dayRange.startRouteM, dayRange.endRouteM);
    if (!slices.length) return;
    const group = L.featureGroup();
    for (const seg of slices) {
      L.polyline(seg.points.map((p) => [p[0], p[1]]), { color: ACCENT, weight: 6, opacity: 1 }).addTo(group);
    }
    group.addTo(map);
    dayLayer.current = group;
    const b = group.getBounds();
    if (b.isValid()) map.fitBounds(b, { padding: [30, 30] });
  }, [dayRange, track]);

  // Enlarge/highlight the marker for the checkpoint hovered anywhere (map or
  // elevation profile).
  useEffect(() => {
    const byId = new Map(checkpoints.map((cp) => [cp.id, cp]));
    for (const [cpId, marker] of cpMarkers.current) {
      const el = marker.getElement?.();
      if (!el) continue;
      el.classList.toggle("cp-marker-active", cpId === hoverCpId);
      // Fade checkpoints that fall outside the selected day.
      const routeM = byId.get(cpId)?.anchor?.routeDistanceM;
      const outside =
        dayRange &&
        Number.isFinite(routeM) &&
        (routeM < dayRange.startRouteM - 1 || routeM > dayRange.endRouteM + 1);
      el.classList.toggle("cp-marker-dim", Boolean(outside));
      marker.setZIndexOffset(cpId === hoverCpId ? 1000 : 0);
    }
  }, [hoverCpId, checkpoints, dayRange]);

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
    </div>
  );
}
