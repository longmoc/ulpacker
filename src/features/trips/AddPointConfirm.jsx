import React from "react";

// Floating "Add a checkpoint here?" confirmation, mirroring the map's Leaflet
// popup. Positioned (absolutely, within a position:relative wrapper) at the
// clicked spot; the caller supplies left/top in pixels.
export default function AddPointConfirm({ left, top, onAdd, onCancel }) {
  return (
    <div className="add-confirm-pop" style={{ left, top }} onClick={(e) => e.stopPropagation()}>
      <div className="map-confirm">
        <span>Add a checkpoint here?</span>
        <div className="map-confirm-actions">
          <button type="button" className="primary" onClick={onAdd}>
            Add
          </button>
          <button type="button" onClick={onCancel}>
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}
