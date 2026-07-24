import React from "react";
import { TrashIcon } from "../../components/icons.jsx";

const km = (m) => (m / 1000).toFixed(1);

// Left sidebar for the Trips view: create-a-trip block + a card per trip.
// Reuses the packs-sidebar structure (sticky on desktop, its own scroll region).
// A trip starts empty; the GPX is imported from inside the workspace (which then
// offers Replace GPX), keeping the two ingress paths — GPX and trip JSON —
// consistent with the workspace's own menu.
export default function TripsSidebar({ trips, packs, activeTripId, onSelect, onDelete, onCreateTrip }) {
  const packName = (packId) => packs.find((p) => p.id === packId)?.name || "";

  return (
    <aside className="panel packs-panel trips-panel">
      <div className="panel-head">
        <h2>Trips</h2>
        <span>{trips.length}</span>
      </div>

      <div className="new-pack-form trip-create">
        <button type="button" onClick={() => onCreateTrip()}>
          Create trip
        </button>
      </div>

      <div className="pack-cards">
        {trips.length === 0 && (
          <p className="trip-empty-hint">No trips yet. Create a trip, then import a GPX to plan a route.</p>
        )}
        {trips.map((trip) => {
          const hasRoute = (trip.trackRef?.pointCount || 0) > 0 || trip.stats.distanceM > 0;
          return (
          <div className="pack-card-wrap" key={trip.id}>
            <button
              type="button"
              className={`pack-card trip-card ${trip.id === activeTripId ? "active" : ""} ${
                trip.image ? "has-image" : ""
              }`}
              style={trip.image ? { "--pack-img": `url(${trip.image})` } : undefined}
              onClick={() => onSelect(trip.id)}
            >
              <strong>{trip.name}</strong>
              <small>{trip.packId ? `🎒 ${packName(trip.packId)}` : "No pack linked"}</small>
              <span>
                {hasRoute ? (
                  <>
                    {km(trip.stats.distanceM)} km
                    {trip.stats.ascentM != null && ` · +${trip.stats.ascentM} m`}
                  </>
                ) : (
                  "No route yet"
                )}
              </span>
            </button>
            <button
              type="button"
              className="pack-card-delete"
              title="Delete trip"
              aria-label="Delete trip"
              onClick={(e) => {
                e.stopPropagation();
                if (window.confirm(`Delete trip "${trip.name}"?`)) onDelete(trip.id);
              }}
            >
              <TrashIcon />
            </button>
          </div>
          );
        })}
      </div>
    </aside>
  );
}
