import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  BASEMAPS,
  TILE_CACHE,
  TILE_LEVELS,
  MAX_TILES,
  routeTiles,
  sampleForTiles,
  estimateBytes,
  formatBytes,
  tileUrl
} from "../../lib/tiles.js";
import { DownloadIcon, TrashIcon, CloseIcon } from "../../components/icons.jsx";

// How many tiles to fetch at once. Kept low on purpose: these are volunteer-run
// tile servers, and a saved trail is a one-off job, not something to race.
const CONCURRENCY = 4;

// "Save this trail's basemap on the device" — a bounded download of the tiles
// along the route, kept in its own cache that the service worker reads from.
export default function OfflineMaps({ track, basemap, onChange }) {
  const [open, setOpen] = useState(false);
  const [level, setLevel] = useState("standard");
  const [saved, setSaved] = useState(null); // { count } already on the device
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(0);
  const [error, setError] = useState("");
  const cancel = useRef(false);

  const supported = typeof caches !== "undefined";

  // Tile keys per level, for the corridor along this track.
  const plans = useMemo(() => {
    if (!track) return {};
    const sampled = sampleForTiles(track.segments);
    const out = {};
    for (const lv of TILE_LEVELS) out[lv.id] = routeTiles(sampled, { zooms: lv.zooms });
    return out;
  }, [track]);

  const keys = plans[level] || [];
  const tooMany = keys.length > MAX_TILES;

  const refreshSaved = async () => {
    if (!supported) return;
    try {
      const cache = await caches.open(TILE_CACHE);
      setSaved({ count: (await cache.keys()).length });
      onChange?.();
    } catch {
      setSaved(null);
    }
  };

  useEffect(() => {
    if (open) refreshSaved();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  const save = async () => {
    setError("");
    setBusy(true);
    setDone(0);
    cancel.current = false;
    try {
      // Ask the browser not to evict this on a storage squeeze.
      await navigator.storage?.persist?.().catch(() => {});
      const bm = BASEMAPS[basemap] || BASEMAPS.standard;
      const cache = await caches.open(TILE_CACHE);
      const queue = [...keys];
      let finished = 0;
      const worker = async () => {
        while (queue.length && !cancel.current) {
          const key = queue.pop();
          const url = tileUrl(bm.url, key, bm.subdomains);
          try {
            // CORS (not no-cors): an opaque response would be unreadable for
            // size accounting and is padded heavily against the storage quota.
            const res = await fetch(url, { mode: "cors", cache: "no-cache" });
            if (res.ok) await cache.put(url, res);
          } catch {
            // A missing tile shouldn't abort the trail.
          }
          finished += 1;
          setDone(finished);
        }
      };
      await Promise.all(Array.from({ length: CONCURRENCY }, worker));
      await refreshSaved();
    } catch (e) {
      setError(e?.message || "Could not save the map.");
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    await caches.delete(TILE_CACHE);
    await refreshSaved();
  };

  if (!track) return null;

  return (
    <>
      <button
        type="button"
        className={`map-full-btn offline-btn ${saved?.count ? "saved" : ""}`}
        title="Save this trail's map for offline use"
        aria-label="Save map for offline use"
        aria-pressed={open}
        onClick={() => setOpen((v) => !v)}
      >
        <DownloadIcon size={15} />
      </button>

      {open && (
        <div className="offline-panel">
          <div className="map-fs-head">
            <strong>Offline map</strong>
            <button type="button" title="Close" aria-label="Close" onClick={() => setOpen(false)}>
              <CloseIcon size={14} />
            </button>
          </div>

          {!supported ? (
            <p className="offline-note">This browser can’t store maps offline.</p>
          ) : (
            <>
              <p className="offline-note">
                Saves the <strong>{(BASEMAPS[basemap] || BASEMAPS.standard).label}</strong> basemap
                along this route, so it still draws with no signal.
              </p>

              <div className="offline-levels">
                {TILE_LEVELS.map((lv) => {
                  const n = (plans[lv.id] || []).length;
                  return (
                    <label key={lv.id} className={`offline-level ${level === lv.id ? "active" : ""}`}>
                      <input
                        type="radio"
                        name="offline-level"
                        checked={level === lv.id}
                        disabled={busy}
                        onChange={() => setLevel(lv.id)}
                      />
                      <span className="offline-level-name">{lv.label}</span>
                      <span className="offline-level-hint">{lv.hint}</span>
                      <span className="offline-level-size">
                        {n.toLocaleString()} tiles · ~{formatBytes(estimateBytes(n))}
                      </span>
                    </label>
                  );
                })}
              </div>

              {busy ? (
                <>
                  <div className="offline-progress">
                    <div
                      className="offline-progress-bar"
                      style={{ width: `${keys.length ? (done / keys.length) * 100 : 0}%` }}
                    />
                  </div>
                  <div className="offline-actions">
                    <span className="offline-note">
                      {done.toLocaleString()} / {keys.length.toLocaleString()}
                    </span>
                    <button type="button" onClick={() => (cancel.current = true)}>
                      Stop
                    </button>
                  </div>
                </>
              ) : (
                <div className="offline-actions">
                  <button type="button" className="primary" disabled={tooMany} onClick={save}>
                    <DownloadIcon size={14} />
                    Save map
                  </button>
                  {saved?.count > 0 && (
                    <button type="button" className="offline-remove" onClick={remove}>
                      <TrashIcon size={14} />
                      Remove ({saved.count.toLocaleString()})
                    </button>
                  )}
                </div>
              )}

              {tooMany && (
                <p className="offline-note warn">
                  That’s more than {MAX_TILES.toLocaleString()} tiles — pick a lower detail level.
                </p>
              )}
              {error && <p className="offline-note warn">{error}</p>}
              <p className="offline-note dim">
                Map data © OpenStreetMap contributors. Please keep downloads to routes you’ll walk.
              </p>
            </>
          )}
        </div>
      )}
    </>
  );
}
