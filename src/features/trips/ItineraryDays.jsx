import React, { useMemo } from "react";
import { buildDays, buildCumulatives } from "../../lib/trail.js";

const km = (m) => (m / 1000).toFixed(1);

// Derived day-by-day itinerary. Days come from overnight checkpoints; nothing
// here is persisted.
export default function ItineraryDays({ trip, track }) {
  const { days, warnings } = useMemo(() => {
    const cumulatives = buildCumulatives(track.segments);
    return buildDays({ checkpoints: trip.checkpoints, segments: track.segments, cumulatives });
  }, [trip.checkpoints, track]);

  const hasOvernight = trip.checkpoints.some((c) => c.kind === "overnight");

  return (
    <div className="itinerary">
      {!hasOvernight && (
        <p className="empty-hint">Set a checkpoint's category to Overnight (⛺) to split the route into days.</p>
      )}
      {warnings?.map((w, i) => (
        <p key={i} className="status warn">{w}</p>
      ))}
      <div className="day-cards">
        {days.map((day) => (
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
          </div>
        ))}
      </div>
    </div>
  );
}
