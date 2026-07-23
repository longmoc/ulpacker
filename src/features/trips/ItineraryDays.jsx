import React, { useMemo, useState } from "react";
import { buildDays, buildCumulatives } from "../../lib/trail.js";
import Markdown from "./Markdown.jsx";
import { PencilIcon, TrashIcon, PinIcon, TrendUpIcon, TrendDownIcon } from "../../components/icons.jsx";

const km = (m) => (m / 1000).toFixed(1);
// Notes longer than this get clamped to ~2 lines behind "Show more".
const LONG_NOTE = 140;

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
  onDeleteExtraDay,
  onSetStartDay
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

  // Interleave off-route days with trail days and number them in sequence.
  // Trips with a prep/arrival day can start the count at Day 0.
  const base = trip.startDayNumber === 0 ? 0 : 1;
  const ordered = [];
  let num = base;
  for (const day of days) {
    for (const x of extras.filter((e) => e.before === day.startBoundary)) ordered.push({ extra: x, num: num++ });
    ordered.push({ day, num: num++ });
  }
  for (const x of extras.filter((e) => e.before === "finish" || !days.some((d) => d.startBoundary === e.before)))
    ordered.push({ extra: x, num: num++ });
  const dayNum = new Map(ordered.filter((r) => r.day).map((r) => [r.day.startBoundary, r.num]));

  const startEdit = (key, current) => {
    setDraft(current || "");
    setEditing(key);
  };

  const NoteBlock = ({ noteKey, note, onSave }) => {
    const isEditing = editing === noteKey;
    const isLong = note.length > LONG_NOTE;
    const open = expanded[noteKey];
    if (isEditing) {
      return (
        <div className="day-note">
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
        </div>
      );
    }
    if (!note) {
      return (
        <div className="day-note">
          <button type="button" className="link-btn day-note-add" onClick={() => startEdit(noteKey, "")}>
            + Add description
          </button>
        </div>
      );
    }
    return (
      <div className="day-note">
        <div className={`day-note-body ${isLong && !open ? "clamped" : ""}`}>
          <Markdown text={note} />
        </div>
        {isLong && (
          <div className="day-note-more">
            <button
              type="button"
              className="link-btn"
              onClick={() => setExpanded((p) => ({ ...p, [noteKey]: !p[noteKey] }))}
            >
              {open ? "Show less" : "Show more"}
            </button>
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="itinerary">
      <div className="trip-section-head itinerary-head">
        <h3 className="itinerary-title">Itinerary</h3>
        <div className="itinerary-tools">
          {selectedDay != null && (
            <button type="button" className="link-btn" onClick={() => onSelectDay?.(null)}>
              Clear day highlight
            </button>
          )}
          <button type="button" className="link-btn" onClick={() => setAdding((v) => !v)}>
            + Add off-route day
          </button>
          <label className="day0-toggle" title="Number the first card Day 0 (a prep / arrival day)">
            <input
              type="checkbox"
              checked={base === 0}
              onChange={(e) => onSetStartDay?.(e.target.checked ? 0 : 1)}
            />
            Start at Day 0
          </label>
        </div>
      </div>

      {!hasOvernight && (
        <p className="empty-hint">Set a checkpoint's category to Overnight (⛺) to split the route into days.</p>
      )}
      {warnings?.map((w, i) => (
        <p key={i} className="status warn">{w}</p>
      ))}

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
                before Day {dayNum.get(d.startBoundary)}
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
          const n = row.num;
          if (row.extra) {
            const x = row.extra;
            const key = `x:${x.id}`;
            return (
              <div key={x.id} className="day-card off-route">
                <div className="day-top">
                  <div className="day-head">
                    Day {n} · {x.title}
                    <span className="cp-flag off-route-badge">off-route</span>
                  </div>
                  <div className="day-card-actions">
                    <button
                      type="button"
                      className="icon-btn"
                      title="Edit description"
                      aria-label="Edit description"
                      onClick={() => startEdit(key, x.note || "")}
                    >
                      <PencilIcon />
                    </button>
                    <button
                      type="button"
                      className="icon-btn danger"
                      title="Remove day"
                      aria-label="Remove day"
                      onClick={() => onDeleteExtraDay?.(x.id)}
                    >
                      <TrashIcon />
                    </button>
                  </div>
                </div>
                <div className="day-stats muted">Not on the track — no distance or elevation counted.</div>
                <NoteBlock
                  noteKey={key}
                  note={x.note || ""}
                  onSave={() => {
                    onUpdateExtraDay?.(x.id, { note: draft });
                    setEditing(null);
                    setDraft("");
                  }}
                />
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
              <div className="day-top">
                <div className="day-head">
                  Day {n} · {day.startName || "Start"} → {day.endName || "Finish"}
                </div>
                <div className="day-card-actions" onClick={(e) => e.stopPropagation()}>
                  <button
                    type="button"
                    className="icon-btn"
                    title="Edit description"
                    aria-label="Edit description"
                    onClick={() => startEdit(key, notes[key] || "")}
                  >
                    <PencilIcon />
                  </button>
                </div>
              </div>

              <div className="day-stats">
                <span className="day-stat">
                  <PinIcon size={14} />
                  <b>{km(day.distanceM)} km</b>
                </span>
                {day.ascentM != null && (
                  <>
                    <span className="day-stat up">
                      <TrendUpIcon size={14} />
                      <b>{day.ascentM.toLocaleString()} m</b>
                    </span>
                    <span className="day-stat down">
                      <TrendDownIcon size={14} />
                      <b>{day.descentM.toLocaleString()} m</b>
                    </span>
                  </>
                )}
                {day.elevationCoverage > 0 && day.elevationCoverage < 1 && (
                  <span className="cp-flag partial" title="Partial elevation data">partial ele</span>
                )}
                {day.segmentBreaks > 0 && (
                  <span className="cp-flag" title="Track gap within this day">{day.segmentBreaks} gap</span>
                )}
              </div>

              <div onClick={(e) => e.stopPropagation()}>
                <NoteBlock
                  noteKey={key}
                  note={notes[key] || ""}
                  onSave={() => {
                    onSetDayNote?.(key, draft);
                    setEditing(null);
                    setDraft("");
                  }}
                />
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
