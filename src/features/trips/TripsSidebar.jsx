import React, { useRef } from "react";

const km = (m) => (m / 1000).toFixed(1);

// Left sidebar for the Trips view: import-to-create block + a card per trip.
// Reuses the packs-sidebar structure (sticky on desktop, its own scroll region).
export default function TripsSidebar({ trips, packs, activeTripId, onSelect, onDelete, onImportGpx }) {
  const fileRef = useRef(null);
  const packName = (packId) => packs.find((p) => p.id === packId)?.name || "";

  return (
    <aside className="panel packs-panel trips-panel">
      <div className="panel-head">
        <h2>Trips</h2>
        <span>{trips.length}</span>
      </div>

      <div className="new-pack-form trip-create">
        <button type="button" onClick={() => fileRef.current?.click()}>
          Import GPX
        </button>
        <input
          ref={fileRef}
          type="file"
          accept=".gpx,application/gpx+xml,application/xml,text/xml"
          hidden
          onChange={(e) => {
            const file = e.target.files?.[0];
            if (file) onImportGpx(file);
            e.target.value = "";
          }}
        />
      </div>

      <div className="pack-cards">
        {trips.length === 0 && (
          <p className="trip-empty-hint">No trips yet. Import a GPX file to plan a route.</p>
        )}
        {trips.map((trip) => (
          <div className="pack-card-wrap" key={trip.id}>
            <button
              type="button"
              className={`pack-card trip-card ${trip.id === activeTripId ? "active" : ""}`}
              onClick={() => onSelect(trip.id)}
            >
              <strong>{trip.name}</strong>
              <small>{trip.packId ? `🎒 ${packName(trip.packId)}` : "No pack linked"}</small>
              <span>
                {km(trip.stats.distanceM)} km
                {trip.stats.ascentM != null && ` · +${trip.stats.ascentM} m`}
              </span>
            </button>
            <button
              type="button"
              className="pack-card-delete"
              title="Delete trip"
              onClick={(e) => {
                e.stopPropagation();
                if (window.confirm(`Delete trip "${trip.name}"?`)) onDelete(trip.id);
              }}
            >
              ×
            </button>
          </div>
        ))}
      </div>
    </aside>
  );
}
