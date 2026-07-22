import React, { useEffect, useRef } from "react";
import L from "leaflet";
import "leaflet/dist/leaflet.css";

const ACCENT = "#1b5e3f";
const GREEN = "#2e9e5b";
const RED = "#b42318";

// Real basemap (OpenStreetMap tiles) with the track drawn on top. Uses vector
// CircleMarkers only — no marker image assets — so it stays within the app's
// locked-down CSP (the tile origin is allow-listed in vite.config.js). Falls
// back to the SVG TrackShape via the parent when the user prefers it / offline.
export default function TrackMap({ track, checkpoints, onAddAt, highlight }) {
  const elRef = useRef(null);
  const mapRef = useRef(null);
  const trackLayer = useRef(null);
  const cpLayer = useRef(null);
  const hoverMarker = useRef(null);
  const onAddRef = useRef(onAddAt);
  onAddRef.current = onAddAt;

  // Init the map once.
  useEffect(() => {
    const map = L.map(elRef.current, { zoomControl: true, attributionControl: true });
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      maxZoom: 17,
      attribution: "© OpenStreetMap contributors"
    }).addTo(map);
    map.on("click", (e) => onAddRef.current?.(e.latlng.lat, e.latlng.lng));
    mapRef.current = map;
    // The container starts at its final size, but guard against a 0-size init.
    setTimeout(() => map.invalidateSize(), 0);
    return () => {
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
    const group = L.featureGroup();
    for (const cp of checkpoints) {
      L.circleMarker([cp.anchor.lat, cp.anchor.lng], {
        radius: 5,
        color: ACCENT,
        weight: 2,
        fillColor: cp.overnight ? ACCENT : "#fff",
        fillOpacity: 1
      })
        .bindTooltip(cp.name || "Checkpoint", { direction: "top" })
        .addTo(group);
    }
    group.addTo(map);
    cpLayer.current = group;
  }, [checkpoints]);

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
      <div className="track-legend">
        <span className="dot start" /> Start
        <span className="dot end" /> Finish
        {onAddAt && <span className="track-hint">· click the map to add a checkpoint</span>}
      </div>
    </div>
  );
}
