# ULPacker

ULPacker is a local-first React app for building backpacking pack lists with a reusable gear library. It borrows the fast pack-list workflow from LighterPack and the pack/library split from PackWizard, while keeping items around even when their pack quantity is `0`. Data lives in the browser; signing in with Google optionally syncs it to your own Google Drive.

Live demo: https://longmoc.github.io/ulpacker/

## Features

- Manage multiple packs (up to 20) from the `Packs` view: create, rename, reorder by drag, delete, and switch from the sidebar.
- Give each pack a cover image — cropped to 3:1 in-app (react-easy-crop), shown as a banner in the pack view and as the sidebar card background.
- Hover a pack card for a quick preview: cover, description, and all five weight totals.
- Keep reusable gear in a separate `Gear Library` view with its own sidebar (overview stats + category filter).
- Add library gear to any pack via the Add-to-Pack dialog: pick a pack card, then a category (the item's own, one of the pack's, or a new one).
- Group pack items by category with editable category headings; drag the row handle to reorder items, drag category headers to reorder groups.
- Add items directly inside each category group, with semi-auto-fill suggestions from the gear library while typing.
- Keep pack item quantity at `0` without deleting the underlying gear (optionally hidden via Settings).
- Mark each pack item as `Base`, `Consumable`, or `Worn`; only one special flag can be active at once.
- Edit item weight — and price, when enabled — directly in the pack list.
- Track per-variant prices: a `Show prices` setting adds a price column to the pack list, the chart legend, and a total price to the breakdown.
- Flag gear as favorite (★) and/or to-buy (cart), from the library or the pack; filter both views by those markers.
- Visualize carried weight with a donut chart, category percentages, and total/base/consumable/worn breakdown.
- Plan trips in the `Trips` view: import a GPX track, see an elevation profile and a 2D track shape, mark checkpoints, and get a day-by-day itinerary.
- Sign in with Google to sync everything to your Drive (`appDataFolder`) across devices — or use the app fully offline without an account.
- Import from LighterPack by URL or CSV; export a pack back to LighterPack-compatible CSV.
- Export and import the whole profile as a JSON file (packs, gear, and trips with their tracks).

## Gear Library

Library gear stores the reusable product-level data:

- `name`: product name.
- `itemType`: type such as `Tent`, `Backpack`, or `Fresh Food`.
- `description`: extra product details.
- `categories`: multiple categories per gear item, edited as chips.
- `variants`: up to 9 named options, each with a weight in grams and a price (variant names are preserved).
- `favorite` / `purchase`: the ★ and to-buy markers.

The library view has a left sidebar with overview stats (items / variants / categories) and a category list with counts — click a category to filter the table.

Editing a variant's weight in the library updates every pack item that uses that variant; prices are always read live from the variant.

A brand-new install (empty storage) is seeded with a few sample gear items
(`Backpack`, `Rain jacket`, `Egg`) so the app is not empty on first run. The
seed is only applied when storage is empty — deleting a seeded item is
permanent and it will not reappear on reload.

Deleting gear from the library also removes pack items that reference that gear.

## Pack Items

A pack item references one library gear item, but can still keep pack-specific values:

- Category used in that pack.
- Quantity.
- Current weight in grams.
- Weight type: `base`, `consumable`, or `worn`.
- Variant reference when selected from a multi-variant library item.

This means the same gear can exist in the library once, then appear in different packs or categories with pack-specific quantities and flags. Unit price comes from the referenced variant, so a price edit in either place is reflected everywhere.

## Trips

The `Trips` view turns a GPX file into a route plan. Import a `.gpx` file (up to
20 trips) and a staged preview lets you:

- Pick which track or route to import when the file has more than one (a `<trk>`
  or `<rte>` is never merged with another).
- Import the file's waypoints as checkpoints.

Each trip shows an **elevation profile** (elevation vs. route distance) and a
map of the route. The map has two modes, toggled in its top-right corner:

- **Map** — a real OpenStreetMap basemap (Leaflet). This is the only feature
  that loads external tiles; its origin is allow-listed in the CSP.
- **Shape** — a self-drawn 2D SVG of the track, with no tiles and no network
  calls (the offline fallback).

Hovering the elevation profile highlights the matching point on the map. Click
the profile (by distance) or the map (by location) to drop a checkpoint; you can
also add one at an explicit distance, split the route into N days (snapped to
existing checkpoints and segment boundaries), or auto-detect prominent passes
and high/low points from the elevation. A trip can optionally **link to a pack**;
deleting that pack just unlinks it (the trip is kept).

Each checkpoint has a **category** — Overnight (⛺), Water (💧), Resupply (🛒),
Pass/summit (⛰️), Viewpoint (📷), Hazard (⚠️), or Landmark (📍) — shown as a
distinct marker on the map and dot on the profile. Only **Overnight** stops split
the route into days. Imported GPX waypoints are auto-categorised from their names
using hiking vocabulary (e.g. "Rest/water — …" → Water, "Weather gate — Col …" →
Pass), and every checkpoint's category can be changed from its row.

A few correctness details worth knowing:

- The track is stored as **segments** (`<trkseg>` boundaries). The gap between two
  segments is never counted as distance — it appears as a break marker in the
  profile and a `gap` badge on any day that spans it.
- Distance / ascent / descent / min–max elevation are **recomputed from the
  geometry** whenever a trip is imported, restored, or pulled from Drive — cached
  numbers in a backup are never trusted. Ascent uses a 5-point moving average to
  suppress GPS jitter, reset at each segment and at each elevation gap. A track
  with no elevation reports `—` rather than zeros.
- Mark a checkpoint as an **overnight stop** (🌙) to split the route into days;
  each day's distance and ascent/descent are derived, never stored.
- Checkpoints are anchored to `(segmentIndex, distance-along-segment)` plus their
  original coordinates, so **replacing a trip's GPX** re-snaps them onto the new
  track instead of losing them.
- GPX timestamps, links, and extensions are **not** stored (privacy by default).
  Files with a `<!DOCTYPE>`/`<!ENTITY>` declaration are rejected before parsing.

## Google Drive Sync

Signing in (Google Identity Services, token flow — no client secret) stores a single
`ulpacker-v4.json` in your Drive's hidden `appDataFolder`. Sync is last-write-wins by
`updatedAt`: local edits push (debounced), sign-in pulls, and the newer copy wins.
Unedited/default data carries an empty `updatedAt` so a fresh device can never
overwrite real cloud data on first sign-in.

The v4 file holds both the light document and the trip **tracks** in one bundle.
A previous-generation client only reads/writes the older `ulpacker.json`, so it can
never pull-then-push the v4 bundle and strip Trips via last-write-wins. On the first
v4 sync the app reads the old `ulpacker.json` once to migrate, then leaves it in
place for rollback. **After updating, refresh the app on every device** so no tab is
still running the pre-Trips build.

Setup requires a Google OAuth client ID exposed as `VITE_GOOGLE_CLIENT_ID`
(a `.env.local` entry for local dev; a repository **variable** of the same name for
the deploy workflow). Scopes: `openid email profile` + `drive.appdata`. Without the
variable the sign-in UI is hidden and the app works purely offline.

## Import from LighterPack

In the pack workspace, the `Import Pack` menu offers two sources, each opening its own dialog, plus `Export to CSV` for the reverse direction:

- **From URL** — a public `lighterpack.com` URL.
- **From CSV file** — a LighterPack CSV export (file is staged first so you can review the mapping before importing).

Both share the same mapping options:

- `Name -> Name, Description -> Description`
- `Description -> Name, Name -> Item Type`
- Optional item type autofill from category.
- Optional description field from detected variant text.

The CSV parser understands real LighterPack exports: it reads the `desc` column
and treats the literal `Worn` / `Consumable` column markers (as well as
`yes/true/1`) as flags. Imported gear is merged into the library and added to
the active pack.

> **URL import requires a server.** It calls the Vite proxy in `vite.config.js`,
> which only exists while running `npm run dev` / `npm run preview`. A static
> build (e.g. GitHub Pages) has no proxy, so URL import will not work there —
> use CSV import or manual entry instead. The proxy only allows `lighterpack.com`
> and `www.lighterpack.com`.

## Profile Export / Import

The account (profile) menu in the header holds the JSON backup actions:

- **Export Profile** downloads all gear, packs, and pack items as a JSON file.
- **Import Profile** replaces all current data with the contents of a backup file (after confirmation).

Because the data lives in browser `localStorage` (which is per-origin), Export/Import Profile is also the way to move your data between machines without Google sync, or to recover from a bad sync (restoring while signed in re-pushes the restored data to Drive).

## Merge And Migration

The library merge key is:

```text
name + itemType
```

The comparison is case-insensitive and trimmed.

When adding or importing gear:

- Missing categories are appended into `categories`.
- New non-zero weights become variants when that weight is not already present (existing variant names and ids are preserved).
- Zero-weight variants are removed when any non-zero variant exists.
- A single zero-weight variant is kept only when all variants are zero.
- Existing description, notes, and markers are preserved when present.

On app load (and on every Drive pull / profile import), stored data is normalized automatically:

- Old single `category` values are migrated into `categories`.
- Duplicate library gear is merged.
- Pack item gear IDs are remapped to the merged gear IDs.
- Invalid pack items are dropped.
- Missing or invalid variants fall back to the first variant.
- Missing fields added by newer versions (variant `price`, markers, pack `image`, …) are backfilled with defaults.

## Data Storage

App data is stored in browser `localStorage`:

```text
ulpacker.v4            gear / packs / pack items / trips (the main document)
ulpacker.tracks        trip GPX geometry, keyed by immutable track id
ulpacker.v3            legacy pre-Trips document (kept for one-way migration + rollback)
ulpacker.settings      UI settings (show prices, hide qty-0, sidebar state)
ulpacker.entered       landing-page dismissal
ulpacker.googleToken   cached short-lived OAuth token (+ expiry)
ulpacker.googleProfile cached account name/email/avatar
ulpacker.googleSignedIn sign-in flag
```

Trip geometry lives in the separate `ulpacker.tracks` "cold" store so editing a
checkpoint only rewrites the light document, not the whole track. A track is
written under a fresh id, then the document is pointed at it, then the old id is
garbage-collected — so a crash mid-import can at worst orphan an unreferenced
track, never leave the document pointing at missing geometry. On first run the app
migrates `ulpacker.v3` into `ulpacker.v4` without touching the v3 copy.

When signed in, the document **and** the tracks are mirrored to `ulpacker-v4.json`
in the Drive `appDataFolder` as one bundle. Pack cover images are embedded in the
document as compressed data URLs (1200×400 JPEG), which is why packs are capped at
20; trips are capped at 20 as well.

## Security

- A Content-Security-Policy meta tag is injected into `dist/index.html` at build
  time (GitHub Pages cannot set headers; dev is excluded because Vite's HMR uses
  inline scripts). Any new external origin must be added to the `csp` list in
  `vite.config.js` or it will be blocked in production only. The trip map's
  OpenStreetMap tile origin (`*.tile.openstreetmap.org`) is allow-listed in
  `img-src`; it is the only feature that fetches external resources, and the
  map's **Shape** mode avoids it entirely.
- Imported backups are sanitized: pack cover images must be `data:image/` URLs.
- CSV exports neutralise spreadsheet formula injection (`= + - @` cells are
  prefixed with `'`; the importer strips it again on round-trip).
- GPX and imported bundles are validated against shared hard limits (file size,
  point/segment/trip/checkpoint counts, text length) applied at every entry point,
  and `<!DOCTYPE>`/`<!ENTITY>` declarations are refused before the XML is parsed
  (XXE / entity-expansion surface). Trip/checkpoint/track data from a hostile
  backup is clamped so one malformed trip can never drop valid gear or packs.

## Tech Stack

- React 18
- Vite 5
- react-easy-crop (pack cover cropping)
- Leaflet + OpenStreetMap tiles (trip map basemap)
- Google Identity Services + Drive REST (loaded at runtime, no SDK dependency)
- Plain CSS with design tokens (Inter font, light theme)
- Vitest for unit tests
- Browser `localStorage`

## Run Locally

Install dependencies:

```bash
npm install
```

Start the dev server:

```bash
npm run dev
```

Optional — enable Google sync locally by creating `.env.local`:

```bash
VITE_GOOGLE_CLIENT_ID=<your-oauth-client-id>
```

Run the tests:

```bash
npm test
```

Build production assets:

```bash
npm run build
```

Preview the production build:

```bash
npm run preview
```

## Project Structure

- `src/App.jsx`: React UI and app state.
- `src/components/Landing.jsx`: landing / sign-in gate.
- `src/hooks/useGoogleSync.js`: Google auth + Drive sync lifecycle (token cache, debounced push, pull-on-sign-in).
- `src/lib/util.js`: small helpers (numbers, text, units, array ops).
- `src/lib/gear.js`: gear/variant normalization and merge logic.
- `src/lib/import.js`: LighterPack CSV/HTML parsing, import mapping, CSV export.
- `src/lib/chart.js`: donut-chart geometry and the category color palette.
- `src/lib/trail.js`: pure GPX parsing, geo/elevation metrics, snapping/anchors, itinerary, and SVG geometry.
- `src/lib/storage.js`: defaults, seed, v3→v4 migration, trip/track sanitizers, and the doc+tracks bundle codec.
- `src/lib/sync.js`: last-write-wins resolution between local and cloud data.
- `src/lib/googleAuth.js`: Google Identity Services wrapper (token flow).
- `src/lib/googleDrive.js`: Drive `appDataFolder` REST calls.
- `src/features/trips/`: the Trips UI (sidebar, workspace, GPX import modal, elevation profile, track shape, checkpoints, itinerary).
- `src/lib/__tests__/`: Vitest unit tests for the modules above.
- `src/styles.css`: app styling (CSS variables / design tokens).
- `src/raw_background.jpg`: the illustrated page background.
- `index.html`: Inter font and favicons.
- `public/`: favicon and app icons (cropped from the logo emblem).
- `vite.config.js`: Vite config, LighterPack URL import proxy, build-time CSP injection, and Vitest config.

## Deployment

The app deploys to GitHub Pages via `.github/workflows/deploy.yml`, which runs
the tests, builds, and publishes on every push to `main`. The Vite `base` is set
to `/ulpacker/` for production builds so asset URLs resolve under the Pages path.

To enable it:

- Set the repository's **Settings → Pages → Source** to **GitHub Actions**.
- Add a repository **variable** `VITE_GOOGLE_CLIENT_ID` (Settings → Secrets and
  variables → Actions → Variables) if Google sync should be enabled on the
  deployed site.
