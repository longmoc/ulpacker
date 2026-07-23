import React, { useMemo, useState } from "react";
import { buildDays, buildCumulatives } from "../../lib/trail.js";
import Markdown from "./Markdown.jsx";

const km = (m) => (m / 1000).toFixed(1);
// Longer notes get clamped behind "Show more".
const LONG_NOTE = 260;

// Derived day-by-day itinerary. Days come from overnight checkpoints; nothing
// about the days themselves is persisted — but each day can carry a Markdown
// description, keyed by the boundary that STARTS it (stable across edits).
export default function ItineraryDays({ trip, track, onSetDayNote }) {
  const [editing, setEditing] = useState(null); // boundary key
  const [draft, setDraft] = useState("");
  const [expanded, setExpanded] = useState({});

  const { days, warnings } = useMemo(() => {
    const cumulatives = buildCumulatives(track.segments);
    return buildDays({ checkpoints: trip.checkpoints, segments: track.segments, cumulatives });
  }, [trip.checkpoints, track]);

  const hasOvernight = trip.checkpoints.some((c) => c.kind === "overnight");
  const notes = trip.dayNotes || {};

  const startEdit = (key) => {
    setDraft(notes[key] || "");
    setEditing(key);
  };
  const save = (key) => {
    onSetDayNote?.(key, draft);
    setEditing(null);
    setDraft("");
  };

  return (
    <div className="itinerary">
      {!hasOvernight && (
        <p className="empty-hint">Set a checkpoint's category to Overnight (⛺) to split the route into days.</p>
      )}
      {warnings?.map((w, i) => (
        <p key={i} className="status warn">{w}</p>
      ))}
      <div className="day-cards">
        {days.map((day) => {
          const key = day.startBoundary;
          const note = notes[key] || "";
          const isEditing = editing === key;
          const isLong = note.length > LONG_NOTE;
          const open = expanded[key];
          return (
            <div key={day.index} className="day-card">
              <div className="day-head">
                Day {day.index} · {day.startName || "Start"} → {day.endName || "Finish"}
              </div>
              <div className="day-stats">
                {km(day.distanceM)} km
                {day.ascentM != null && ` · +${day.ascentM} / −${day.descentM} m`}
                {day.elevationCoverage > 0 && day.elevationCoverage < 1 && (
                  <span className="cp-flag partial" title="Partial elevation data"> partial ele</span>
                )}
                {day.segmentBreaks > 0 && <span className="cp-flag" title="Track gap within this day"> {day.segmentBreaks} gap</span>}
              </div>

              <div className="day-note">
                {isEditing ? (
                  <>
                    <textarea
                      className="day-note-input"
                      value={draft}
                      autoFocus
                      rows={6}
                      placeholder={"Description for this day…\n\nSupports **bold**, *italic*, `code`, - bullet lists and 1. numbered lists."}
                      onChange={(e) => setDraft(e.target.value)}
                    />
                    <div className="day-note-actions">
                      <button type="button" className="primary" onClick={() => save(key)}>
                        Save
                      </button>
                      <button type="button" onClick={() => setEditing(null)}>
                        Cancel
                      </button>
                    </div>
                  </>
                ) : note ? (
                  <>
                    <div className={`day-note-body ${isLong && !open ? "clamped" : ""}`}>
                      <Markdown text={note} />
                    </div>
                    <div className="day-note-actions">
                      {isLong && (
                        <button
                          type="button"
                          className="link-btn"
                          onClick={() => setExpanded((p) => ({ ...p, [key]: !p[key] }))}
                        >
                          {open ? "Show less" : "Show more"}
                        </button>
                      )}
                      <button type="button" className="link-btn" onClick={() => startEdit(key)}>
                        Edit
                      </button>
                    </div>
                  </>
                ) : (
                  <button type="button" className="link-btn" onClick={() => startEdit(key)}>
                    + Add description
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
