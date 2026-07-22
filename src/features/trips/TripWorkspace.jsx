import React, { useMemo, useRef, useState } from "react";
import { id } from "../../lib/util.js";
import {
  anchorAtRouteM,
  buildCumulatives,
  buildDays,
  snapToTrack,
  evenSplitRouteM,
  detectExtrema
} from "../../lib/trail.js";
import ElevationProfile from "./ElevationProfile.jsx";
import TrackShape from "./TrackShape.jsx";
import CheckpointList from "./CheckpointList.jsx";
import ItineraryDays from "./ItineraryDays.jsx";

const km = (m) => (m / 1000).toFixed(1);

export default function TripWorkspace({
  trip,
  track,
  packs,
  onUpdateTrip,
  onDeleteTrip,
  onReplaceGpx,
  onAddCheckpoint,
  onUpdateCheckpoint,
  onDeleteCheckpoint
}) {
  const replaceRef = useRef(null);
  const [addKm, setAddKm] = useState("");
  const [splitDays, setSplitDays] = useState("");
  const [hoverRouteM, setHoverRouteM] = useState(null);

  const cums = useMemo(() => (track ? buildCumulatives(track.segments) : null), [track]);

  const dayCount = useMemo(() => {
    if (!track || !cums) return 0;
    return buildDays({ checkpoints: trip?.checkpoints || [], segments: track.segments, cumulatives: cums }).days.length;
  }, [trip, track, cums]);

  // Point on the track corresponding to the current elevation-profile hover.
  const hoverPoint = useMemo(() => {
    if (hoverRouteM == null || !track || !cums) return null;
    const a = anchorAtRouteM(track.segments, cums, hoverRouteM);
    return { lat: a.lat, lng: a.lng };
  }, [hoverRouteM, track, cums]);

  if (!trip) {
    return (
      <div className="trip-empty">
        <p>Select a trip, or import a GPX file to start planning a route.</p>
      </div>
    );
  }

  const handleReplaceInput = (e) => {
    const file = e.target.files?.[0];
    if (file) onReplaceGpx(file);
    e.target.value = "";
  };

  const pushCheckpoint = (anchor) =>
    onAddCheckpoint({ id: `cp_${id()}`, name: "", note: "", overnight: false, source: "manual", anchor });

  // From an elevation-profile click (route distance).
  const addAtRoute = (routeM) => {
    pushCheckpoint(anchorAtRouteM(track.segments, cums, routeM));
  };

  // From a track-map click (lat/lng snapped onto the track).
  const addAtLatLng = (lat, lng) => {
    pushCheckpoint(snapToTrack(track.segments, lat, lng));
  };

  // From the explicit "at km" input.
  const totalKm = cums ? cums.totalM / 1000 : 0;
  const submitAddKm = () => {
    const km = parseFloat(addKm);
    if (!Number.isFinite(km)) return;
    addAtRoute(Math.max(0, Math.min(totalKm, km)) * 1000);
    setAddKm("");
  };

  const addMany = (items) => {
    for (const it of items) {
      onAddCheckpoint({
        id: `cp_${id()}`,
        name: it.name,
        note: "",
        overnight: Boolean(it.overnight),
        source: "manual",
        anchor: anchorAtRouteM(track.segments, cums, it.routeM)
      });
    }
  };

  // Suggest: evenly split into N days (overnight camps).
  const submitSplitDays = () => {
    const n = parseInt(splitDays, 10);
    if (!Number.isFinite(n) || n < 2) return;
    const splits = evenSplitRouteM(cums.totalM, { days: n });
    if (splits.length === 0) return;
    addMany(splits.map((routeM, i) => ({ routeM, name: `Camp ${i + 1}`, overnight: true })));
    setSplitDays("");
  };

  // Suggest: passes / high & low points from the elevation profile.
  const hasEle = (trip.stats?.elevationCoverage || 0) > 0;
  const suggestHighPoints = () => {
    const ex = detectExtrema(track.segments, cums, { minProminenceM: 120 });
    if (ex.length === 0) {
      window.alert("No prominent high or low points found on this track.");
      return;
    }
    addMany(
      ex.map((e) => ({
        routeM: e.routeM,
        name: `${e.kind === "high" ? "High point" : "Low point"} ${e.ele} m`,
        overnight: false
      }))
    );
  };

  const { stats } = trip;

  return (
    <div className="trip-workspace">
      <div className="workspace-titles trip-titles">
        <input
          className="trip-name-input"
          value={trip.name}
          onChange={(e) => onUpdateTrip({ name: e.target.value })}
          placeholder="Trip name"
        />
        <input
          className="trip-desc-input"
          value={trip.description}
          onChange={(e) => onUpdateTrip({ description: e.target.value })}
          placeholder="Description"
        />
        <div className="trip-actions">
          <label className="trip-pack-link">
            Pack:
            <select value={trip.packId} onChange={(e) => onUpdateTrip({ packId: e.target.value })}>
              <option value="">No pack</option>
              {packs.map((p) => (
                <option key={p.id} value={p.id}>
                  {p.name}
                </option>
              ))}
            </select>
          </label>
          <button type="button" onClick={() => replaceRef.current?.click()}>
            Replace GPX
          </button>
          <input
            ref={replaceRef}
            type="file"
            accept=".gpx,application/gpx+xml,application/xml,text/xml"
            hidden
            onChange={handleReplaceInput}
          />
          <button
            type="button"
            className="danger"
            onClick={() => window.confirm(`Delete trip "${trip.name}"?`) && onDeleteTrip()}
          >
            Delete
          </button>
        </div>
      </div>

      {!track ? (
        <div className="track-missing">
          <p>This trip's track data is missing. Re-import a GPX file to restore it.</p>
          <button type="button" className="primary" onClick={() => replaceRef.current?.click()}>
            Re-import GPX
          </button>
        </div>
      ) : (
        <>
          <div className="summary-grid trip-summary">
            <div className="summary-card">
              <small>Distance</small>
              <strong>{km(stats.distanceM)} km</strong>
            </div>
            <div className="summary-card">
              <small>Ascent</small>
              <strong>{stats.ascentM != null ? `+${stats.ascentM} m` : "—"}</strong>
            </div>
            <div className="summary-card">
              <small>Descent</small>
              <strong>{stats.descentM != null ? `−${stats.descentM} m` : "—"}</strong>
            </div>
            <div className="summary-card">
              <small>High / Low</small>
              <strong>{stats.maxEle != null ? `${stats.maxEle} / ${stats.minEle} m` : "—"}</strong>
            </div>
            <div className="summary-card">
              <small>Days</small>
              <strong>{dayCount}</strong>
            </div>
            <div className="summary-card">
              <small>Track</small>
              <strong>
                {trip.trackRef.pointCount.toLocaleString()} pts · ~{Math.round(trip.trackRef.sizeBytes / 1024)} KB
              </strong>
            </div>
          </div>

          {stats.elevationCoverage > 0 && stats.elevationCoverage < 1 && (
            <p className="status warn">
              Partial elevation data ({Math.round(stats.elevationCoverage * 100)}% of points) — ascent/descent
              are approximate.
            </p>
          )}

          <div className="trip-graphics">
            <ElevationProfile
              track={track}
              checkpoints={trip.checkpoints}
              onAddAt={addAtRoute}
              onHover={setHoverRouteM}
            />
            <TrackShape
              track={track}
              checkpoints={trip.checkpoints}
              onAddAt={addAtLatLng}
              highlight={hoverPoint}
            />
          </div>

          <section className="trip-section">
            <div className="trip-section-head">
              <h3>Checkpoints</h3>
              <div className="add-km">
                <span>Add at</span>
                <input
                  type="number"
                  step="0.1"
                  min="0"
                  max={totalKm.toFixed(1)}
                  value={addKm}
                  placeholder="km"
                  onChange={(e) => setAddKm(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && submitAddKm()}
                />
                <span>km</span>
                <button type="button" onClick={submitAddKm} disabled={addKm === ""}>
                  Add
                </button>
              </div>
            </div>
            <div className="suggest-bar">
              <span className="suggest-label">Suggest:</span>
              <span className="suggest-group">
                Split into
                <input
                  type="number"
                  min="2"
                  max="30"
                  value={splitDays}
                  placeholder="N"
                  onChange={(e) => setSplitDays(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && submitSplitDays()}
                />
                days
                <button type="button" onClick={submitSplitDays} disabled={splitDays === ""}>
                  Add camps
                </button>
              </span>
              <button
                type="button"
                onClick={suggestHighPoints}
                disabled={!hasEle}
                title={hasEle ? "" : "This track has no elevation data"}
              >
                Detect passes &amp; high points
              </button>
            </div>
            <CheckpointList
              checkpoints={trip.checkpoints}
              onUpdate={onUpdateCheckpoint}
              onDelete={onDeleteCheckpoint}
            />
          </section>

          <section className="trip-section">
            <h3>Itinerary</h3>
            <ItineraryDays trip={trip} track={track} />
          </section>
        </>
      )}
    </div>
  );
}
