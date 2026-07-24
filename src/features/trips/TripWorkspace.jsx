import React, { useMemo, useRef, useState } from "react";
import { id } from "../../lib/util.js";
import {
  anchorAtRouteM,
  buildCumulatives,
  buildDays,
  snapToTrack,
  suggestDaySplits,
  detectExtrema,
  CHECKPOINT_KINDS,
  CHECKPOINT_KIND_KEYS,
  dayColor
} from "../../lib/trail.js";
import ElevationProfile from "./ElevationProfile.jsx";
import TrackShape from "./TrackShape.jsx";
import TrackMap from "./TrackMap.jsx";
import CheckpointList from "./CheckpointList.jsx";
import ItineraryDays from "./ItineraryDays.jsx";
import {
  PencilIcon,
  TrashIcon,
  ImageIcon,
  PinIcon,
  TrendUpIcon,
  TrendDownIcon,
  PeakIcon,
  ClockIcon
} from "../../components/icons.jsx";

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
  onDeleteCheckpoint,
  onSetDayNote,
  onSetExtraDays,
  onPickCover
}) {
  const replaceRef = useRef(null);
  const coverRef = useRef(null);
  const [addKm, setAddKm] = useState("");
  const [splitDays, setSplitDays] = useState("");
  const [cpOpen, setCpOpen] = useState(false);
  const [cpFilter, setCpFilter] = useState(null); // kind filter, shared with map/profile
  const [hoverCpId, setHoverCpId] = useState(null);
  const [openTool, setOpenTool] = useState(null); // "km" | "split" | null
  const [selectedDay, setSelectedDay] = useState(null);
  const [hoverRouteM, setHoverRouteM] = useState(null);
  const [mapMode, setMapMode] = useState(() => {
    try {
      return localStorage.getItem("ulpacker.tripMapMode") === "shape" ? "shape" : "map";
    } catch {
      return "map";
    }
  });
  const chooseMode = (m) => {
    setMapMode(m);
    try {
      localStorage.setItem("ulpacker.tripMapMode", m);
    } catch {
      // ignore
    }
  };

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

  // Route range of the selected day (drives the dim/highlight on map + profile).
  // Must stay above the early return below — hooks can't be conditional.
  const dayRange = useMemo(() => {
    if (selectedDay == null || !cums || !track || !trip) return null;
    const { days } = buildDays({ checkpoints: trip.checkpoints, segments: track.segments, cumulatives: cums });
    const d = days.find((x) => x.index === selectedDay);
    return d ? { startRouteM: d.startRouteM, endRouteM: d.endRouteM } : null;
  }, [selectedDay, trip, track, cums]);

  // One colour band per trail day, shared by the map, the profile and the
  // itinerary card borders so a day reads the same everywhere.
  const dayBands = useMemo(() => {
    if (!cums || !track || !trip) return [];
    const { days } = buildDays({ checkpoints: trip.checkpoints, segments: track.segments, cumulatives: cums });
    if (days.length < 2) return [];
    return days.map((d, i) => ({
      index: d.index,
      startRouteM: d.startRouteM,
      endRouteM: d.endRouteM,
      color: dayColor(i)
    }));
  }, [trip, track, cums]);

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
    onAddCheckpoint({ id: `cp_${id()}`, name: "", note: "", kind: "poi", source: "manual", anchor });

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
        kind: it.kind || "poi",
        source: "manual",
        anchor: anchorAtRouteM(track.segments, cums, it.routeM)
      });
    }
  };

  // Suggest: split into N days, snapping each boundary to the best nearby
  // anchor — an existing checkpoint (overnight first) or a segment boundary —
  // before falling back to an even position.
  const submitSplitDays = () => {
    const n = parseInt(splitDays, 10);
    if (!Number.isFinite(n) || n < 2) return;
    const plan = suggestDaySplits(cums.totalM, { days: n }, {
      checkpoints: trip.checkpoints,
      boundaries: trip.boundaries || []
    });
    if (plan.length === 0) return;
    let camp = 1;
    for (const it of plan) {
      if (it.source === "checkpoint" && it.id) {
        onUpdateCheckpoint(it.id, { kind: "overnight" });
      } else {
        onAddCheckpoint({
          id: `cp_${id()}`,
          name: `Camp ${camp}`,
          note: "",
          kind: "overnight",
          source: "manual",
          anchor: anchorAtRouteM(track.segments, cums, it.routeM)
        });
      }
      camp += 1;
    }
    setSplitDays("");
  };

  // Suggest: a (non-overnight) checkpoint at every segment boundary. Offered
  // only when the track has a handful of segments (not e.g. 20+ OSM ways).
  const boundaries = trip.boundaries || [];
  const canAddSegments = boundaries.length >= 1 && boundaries.length <= 20;
  const addSegmentStops = () => {
    addMany(boundaries.map((routeM, i) => ({ routeM, name: `Stop ${i + 1}`, kind: "poi" })));
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
        kind: e.kind === "high" ? "pass" : "poi"
      }))
    );
  };

  const { stats } = trip;
  const kindCounts = {};
  for (const cp of trip.checkpoints) {
    const k = CHECKPOINT_KINDS[cp.kind] ? cp.kind : "poi";
    kindCounts[k] = (kindCounts[k] || 0) + 1;
  }
  // The category filter applies everywhere: list, elevation profile and map.
  const visibleCheckpoints = cpFilter
    ? trip.checkpoints.filter((cp) => (cp.kind || "poi") === cpFilter)
    : trip.checkpoints;

  const extraDays = trip.extraDays || [];
  const addExtraDay = ({ title, before }) =>
    onSetExtraDays?.([...extraDays, { id: `xd_${id()}`, title, before, note: "" }]);
  const updateExtraDay = (xid, patch) =>
    onSetExtraDays?.(extraDays.map((d) => (d.id === xid ? { ...d, ...patch } : d)));
  const deleteExtraDay = (xid) => onSetExtraDays?.(extraDays.filter((d) => d.id !== xid));

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
          <div className={`trip-hero ${trip.image ? "has-image" : ""}`}>
            <input
              ref={coverRef}
              type="file"
              accept="image/*"
              hidden
              onChange={(e) => onPickCover?.(e)}
            />
            {trip.image ? (
              <div className="pack-cover">
                <img src={trip.image} alt={`${trip.name} cover`} />
                <div className="pack-cover-actions">
                  <button
                    type="button"
                    title="Change cover image"
                    aria-label="Change cover image"
                    onClick={() => coverRef.current?.click()}
                  >
                    <PencilIcon />
                  </button>
                  <button
                    type="button"
                    className="cover-remove"
                    title="Remove cover image"
                    aria-label="Remove cover image"
                    onClick={() => onUpdateTrip({ image: "" })}
                  >
                    <TrashIcon />
                  </button>
                </div>
              </div>
            ) : (
              <button type="button" className="pack-cover-empty" onClick={() => coverRef.current?.click()}>
                <ImageIcon />
                Add cover image
              </button>
            )}

            <div className="trip-stats">
              <div className="trip-stat">
                <span className="trip-stat-value">
                  <PinIcon />
                  <strong>{km(stats.distanceM)}</strong>
                  <em>km</em>
                </span>
                <span className="trip-stat-label">Distance</span>
              </div>
              <div className="trip-stat">
                <span className="trip-stat-value">
                  <TrendUpIcon />
                  <strong>{stats.ascentM != null ? stats.ascentM.toLocaleString() : "—"}</strong>
                  {stats.ascentM != null && <em>m</em>}
                </span>
                <span className="trip-stat-label">Ascent</span>
              </div>
              <div className="trip-stat">
                <span className="trip-stat-value">
                  <TrendDownIcon />
                  <strong>{stats.descentM != null ? stats.descentM.toLocaleString() : "—"}</strong>
                  {stats.descentM != null && <em>m</em>}
                </span>
                <span className="trip-stat-label">Descent</span>
              </div>
              <div className="trip-stat">
                <span className="trip-stat-value">
                  <PeakIcon />
                  <strong>
                    {stats.maxEle != null ? `${stats.maxEle.toLocaleString()} / ${stats.minEle.toLocaleString()}` : "—"}
                  </strong>
                  {stats.maxEle != null && <em>m</em>}
                </span>
                <span className="trip-stat-label">High / Low</span>
              </div>
              <div className="trip-stat">
                <span className="trip-stat-value">
                  <ClockIcon />
                  <strong>{dayCount}</strong>
                  <em>days</em>
                </span>
                <span className="trip-stat-label">Duration</span>
              </div>
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
              checkpoints={visibleCheckpoints}
              onAddAt={addAtRoute}
              onHover={setHoverRouteM}
              hoverCpId={hoverCpId}
              onHoverCheckpoint={setHoverCpId}
              dayRange={dayRange}
              dayBands={dayBands}
            />
            <div className="map-panel">
              <div className="map-toggle">
                <button
                  type="button"
                  className={mapMode === "map" ? "active" : ""}
                  onClick={() => chooseMode("map")}
                >
                  Map
                </button>
                <button
                  type="button"
                  className={mapMode === "shape" ? "active" : ""}
                  onClick={() => chooseMode("shape")}
                >
                  Shape
                </button>
              </div>
              {mapMode === "map" ? (
                <TrackMap
                  key={trip.id}
                  track={track}
                  checkpoints={visibleCheckpoints}
                  onAddAt={addAtLatLng}
                  highlight={hoverPoint}
                  hoverCpId={hoverCpId}
                  onHoverCheckpoint={setHoverCpId}
                  dayRange={dayRange}
                  dayBands={dayBands}
                  startName={trip.startName}
                  finishName={trip.finishName}
                />
              ) : (
                <TrackShape
                  track={track}
                  checkpoints={visibleCheckpoints}
                  onAddAt={addAtLatLng}
                  highlight={hoverPoint}
                  hoverCpId={hoverCpId}
                  dayRange={dayRange}
                  dayBands={dayBands}
                />
              )}
            </div>
          </div>

          <section className="trip-section">
            <div className="trip-section-head">
              <h3>
                <button
                  type="button"
                  className="section-toggle"
                  aria-expanded={cpOpen}
                  onClick={() => setCpOpen((v) => !v)}
                >
                  <span className={`caret ${cpOpen ? "open" : ""}`}>▸</span> Checkpoints
                  <span className="section-count">{trip.checkpoints.length}</span>
                </button>
              </h3>
              {/* Kept visible when the list is collapsed: the filter still
                  drives the map and the elevation profile. */}
              <div className="cp-filters">
                <button
                  type="button"
                  className={`cp-chip ${cpFilter === null ? "active" : ""}`}
                  onClick={() => setCpFilter(null)}
                >
                  All {trip.checkpoints.length}
                </button>
                {CHECKPOINT_KIND_KEYS.filter((k) => kindCounts[k]).map((k) => (
                  <button
                    key={k}
                    type="button"
                    title={CHECKPOINT_KINDS[k].label}
                    className={`cp-chip kind-${k} ${cpFilter === k ? "active" : ""}`}
                    onClick={() => setCpFilter(cpFilter === k ? null : k)}
                  >
                    {CHECKPOINT_KINDS[k].emoji} {kindCounts[k]}
                  </button>
                ))}
              </div>
            </div>
            {cpOpen && (
              <>
            <div className="tool-links">
              <button
                type="button"
                className={`link-btn ${openTool === "km" ? "active" : ""}`}
                onClick={() => setOpenTool(openTool === "km" ? null : "km")}
              >
                Add checkpoint
              </button>
              <button
                type="button"
                className={`link-btn ${openTool === "split" ? "active" : ""}`}
                onClick={() => setOpenTool(openTool === "split" ? null : "split")}
              >
                Split into days
              </button>
              <button
                type="button"
                className="link-btn"
                onClick={suggestHighPoints}
                disabled={!hasEle}
                title={hasEle ? "" : "This track has no elevation data"}
              >
                Detect passes &amp; high points
              </button>
              {canAddSegments && (
                <button
                  type="button"
                  className="link-btn"
                  onClick={addSegmentStops}
                  title="Add a checkpoint at each segment boundary"
                >
                  Add segment stops ({boundaries.length})
                </button>
              )}
            </div>

            {openTool === "km" && (
              <div className="tool-panel">
                <span>Add at</span>
                <input
                  type="number"
                  step="0.1"
                  min="0"
                  max={totalKm.toFixed(1)}
                  value={addKm}
                  placeholder="km"
                  autoFocus
                  onChange={(e) => setAddKm(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && submitAddKm()}
                />
                <span>km of {totalKm.toFixed(1)}</span>
                <button type="button" className="primary" onClick={submitAddKm} disabled={addKm === ""}>
                  Add
                </button>
              </div>
            )}

            {openTool === "split" && (
              <div className="tool-panel">
                <span>Split into</span>
                <input
                  type="number"
                  min="2"
                  max="30"
                  value={splitDays}
                  placeholder="N"
                  autoFocus
                  onChange={(e) => setSplitDays(e.target.value)}
                  onKeyDown={(e) => e.key === "Enter" && submitSplitDays()}
                />
                <span>days</span>
                <button type="button" className="primary" onClick={submitSplitDays} disabled={splitDays === ""}>
                  Add camps
                </button>
              </div>
            )}
            <CheckpointList
              checkpoints={visibleCheckpoints}
              onUpdate={onUpdateCheckpoint}
              onDelete={onDeleteCheckpoint}
              onHoverCheckpoint={setHoverCpId}
            />
              </>
            )}
          </section>

          <section className="trip-section">
            <ItineraryDays
              trip={trip}
              track={track}
              onSetDayNote={onSetDayNote}
              selectedDay={selectedDay}
              onSelectDay={setSelectedDay}
              onAddExtraDay={addExtraDay}
              onUpdateExtraDay={updateExtraDay}
              onDeleteExtraDay={deleteExtraDay}
              onSetStartDay={(n) => onUpdateTrip({ startDayNumber: n })}
              onSetEndpoint={(field, value) => onUpdateTrip({ [field]: value })}
            />
          </section>
        </>
      )}
    </div>
  );
}
