import React, { useMemo, useState } from "react";
import { buildDays, buildCumulatives } from "../../lib/trail.js";
import Markdown from "./Markdown.jsx";

const km = (m) => (m / 1000).toFixed(1);
// Longer notes get clamped behind "Show more".
const LONG_NOTE = 260;

// Derived day-by-day itinerary. Trail days come from overnight checkpoints;
// off-route days (travel/rest/shuttle) are stored on the trip and interleaved,
// carry no distance, and never touch the trail on the map.
export default function ItineraryDays({
  trip,
  track,
  onSetDayNote,
  selectedDay,
  onSelectDay,
  onAddExtraDay,
  onUpdateExtraDay,
  onDeleteExtraDay
}) {
  const [editing, setEditing] = useState(null); // note key
  const [draft, setDraft] = useState("");
  const [expanded, setExpanded] = useState({});
  const [adding, setAdding] = useState(false);
  const [newDay, setNewDay] = useState({ title: "", before: "finish" });

  const { days, warnings } = useMemo(() => {
    const cumulatives = buildCumulatives(track.segments);
    return buildDays({ checkpoints: trip.checkpoints, segments: track.segments, cumulatives });
  }, [trip.checkpoints, track]);

  const hasOvernight = trip.checkpoints.some((c) => c.kind === "overnight");
  const notes = trip.dayNotes || {};
  const extras = trip.extraDays || [];

  // Interleave off-route days with trail days, then number them in sequence.
  const ordered = [];
  for (const day of days) {
    for (const x of extras.filter((e) => e.before === day.startBoundary)) ordered.push({ extra: x });
    ordered.push({ day });
  }
  for (const x of extras.filter((e) => e.before === "finish" || !days.some((d) => d.startBoundary === e.before)))
    ordered.push({ extra: x });

  const startEdit = (key, current) => {
    setDraft(current || "");
    setEditing(key);
  };
  const saveNote = (key) => {
    onSetDayNote?.(key, draft);
    setEditing(null);
    setDraft("");
  };
  const saveExtraNote = (x) => {
    onUpdateExtraDay?.(x.id, { note: draft });
    setEditing(null);
    setDraft("");
  };

  const NoteBlock = ({ noteKey, note, onSave }) => {
    const isEditing = editing === noteKey;
    const isLong = note.length > LONG_NOTE;
    const open = expanded[noteKey];
    return (
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
              <button type="button" className="primary" onClick={onSave}>
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
                  onClick={() => setExpanded((p) => ({ ...p, [noteKey]: !p[noteKey] }))}
                >
                  {open ? "Show less" : "Show more"}
                </button>
              )}
              <button type="button" className="link-btn" onClick={() => startEdit(noteKey, note)}>
                Edit
              </button>
            </div>
          </>
        ) : (
          <button type="button" className="link-btn" onClick={() => startEdit(noteKey, "")}>
            + Add description
          </button>
        )}
      </div>
    );
  };

  let n = 0;
  return (
    <div className="itinerary">
      {!hasOvernight && (
        <p className="empty-hint">Set a checkpoint's category to Overnight (⛺) to split the route into days.</p>
      )}
      {warnings?.map((w, i) => (
        <p key={i} className="status warn">{w}</p>
      ))}

      <div className="itinerary-tools">
        <button type="button" className="link-btn" onClick={() => setAdding((v) => !v)}>
          + Add off-route day
        </button>
        {selectedDay != null && (
          <button type="button" className="link-btn" onClick={() => onSelectDay?.(null)}>
            Clear day highlight
          </button>
        )}
      </div>

      {adding && (
        <div className="tool-panel">
          <input
            placeholder="Travel day, rest day…"
            value={newDay.title}
            autoFocus
            onChange={(e) => setNewDay((d) => ({ ...d, title: e.target.value }))}
          />
          <span>insert</span>
          <select value={newDay.before} onChange={(e) => setNewDay((d) => ({ ...d, before: e.target.value }))}>
            {days.map((d) => (
              <option key={d.index} value={d.startBoundary}>
                before Day {d.index}
              </option>
            ))}
            <option value="finish">at the end</option>
          </select>
          <button
            type="button"
            className="primary"
            onClick={() => {
              onAddExtraDay?.({ title: newDay.title.trim() || "Off-route day", before: newDay.before });
              setNewDay({ title: "", before: "finish" });
              setAdding(false);
            }}
          >
            Add
          </button>
        </div>
      )}

      <div className="day-cards">
        {ordered.map((row) => {
          n += 1;
          if (row.extra) {
            const x = row.extra;
            return (
              <div key={x.id} className="day-card off-route">
                <div className="day-head">
                  Day {n} · {x.title}
                  <span className="cp-flag off-route-badge">off-route</span>
                </div>
                <div className="day-stats">Not on the track — no distance or elevation counted.</div>
                <NoteBlock noteKey={`x:${x.id}`} note={x.note || ""} onSave={() => saveExtraNote(x)} />
                <div className="day-note-actions">
                  <button type="button" className="link-btn" onClick={() => onDeleteExtraDay?.(x.id)}>
                    Remove day
                  </button>
                </div>
              </div>
            );
          }
          const day = row.day;
          const key = day.startBoundary;
          const active = selectedDay === day.index;
          return (
            <div
              key={`d${day.index}`}
              className={`day-card ${active ? "active" : ""}`}
              onClick={() => onSelectDay?.(active ? null : day.index)}
            >
              <div className="day-head">
                Day {n} · {day.startName || "Start"} → {day.endName || "Finish"}
              </div>
              <div className="day-stats">
                {km(day.distanceM)} km
                {day.ascentM != null && ` · +${day.ascentM} / −${day.descentM} m`}
                {day.elevationCoverage > 0 && day.elevationCoverage < 1 && (
                  <span className="cp-flag partial" title="Partial elevation data"> partial ele</span>
                )}
                {day.segmentBreaks > 0 && <span className="cp-flag" title="Track gap within this day"> {day.segmentBreaks} gap</span>}
              </div>
              <div onClick={(e) => e.stopPropagation()}>
                <NoteBlock noteKey={key} note={notes[key] || ""} onSave={() => saveNote(key)} />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
