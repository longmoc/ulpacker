# ULPacker

ULPacker is a local-first React app for building backpacking pack lists with a reusable gear library. It borrows the fast pack-list workflow from LighterPack and the pack/library split from PackWizard, while keeping items around even when their pack quantity is `0`.

Live demo: https://longmoc.github.io/ulpacker/

## Features

- Manage multiple packs from the `Packs` view.
- Keep reusable gear in a separate `Gear Library` view.
- Add library gear into any pack, not only the currently active pack.
- Group pack items by category with editable category headings.
- Add items directly inside each category group.
- Get semi-auto-fill suggestions from the gear library while typing a pack item name.
- Drag gear from the library into a pack list, and drag pack rows to reorder.
- Keep pack item quantity at `0` without deleting the underlying gear.
- Mark each pack item as `Base`, `Consumable`, or `Worn`; only one special flag can be active at once.
- Edit item weight directly in the pack list.
- Visualize carried weight with a donut chart, category percentages, and total/base/consumable/worn breakdown.
- Import from LighterPack by URL or CSV.
- Back up and restore all data as a JSON file.

## Gear Library

Library gear stores the reusable product-level data:

- `name`: product name.
- `itemType`: type such as `Tent`, `Backpack`, or `Fresh Food`.
- `description`: extra product details.
- `categories`: multiple categories per gear item, edited as chips.
- `variants`: named weight options in grams (variant names are preserved).

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

This means the same gear can exist in the library once, then appear in different packs or categories with pack-specific quantities and flags.

## Import from LighterPack

In the pack workspace, the `Import from LighterPack` menu offers two sources, each opening its own dialog:

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

## Backup and Restore

The header has flat `Export` and `Import` menus:

- **Export → Backup to JSON** downloads all gear, packs, and pack items as a JSON file.
- **Import → Restore from JSON** replaces all current data with the contents of a backup file (after confirmation).

Because the data lives in browser `localStorage` (which is per-origin), Backup/Restore is also the way to move your data between machines or from a local dev build to the deployed site.

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
- Existing description and notes are preserved when present.

On app load, stored data is normalized automatically:

- Old single `category` values are migrated into `categories`.
- Duplicate library gear is merged.
- Pack item gear IDs are remapped to the merged gear IDs.
- Invalid pack items are dropped.
- Missing or invalid variants fall back to the first variant.

## Data Storage

All app data is stored in browser `localStorage` under:

```text
ulpacker.v3
```

There is no backend database. Data is browser-local unless exported via Backup to JSON.

## Tech Stack

- React 18
- Vite 5
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
- `src/lib/util.js`: small helpers (numbers, text, units, array ops).
- `src/lib/gear.js`: gear/variant normalization and merge logic.
- `src/lib/import.js`: LighterPack CSV/HTML parsing and import mapping.
- `src/lib/chart.js`: donut-chart geometry and the category color palette.
- `src/lib/storage.js`: defaults, seed, migration, and `localStorage` read.
- `src/lib/__tests__/`: Vitest unit tests for the modules above.
- `src/styles.css`: app styling (CSS variables / design tokens).
- `index.html`: Inter font and favicons.
- `public/`: favicon and app icons (cropped from the logo emblem).
- `vite.config.js`: Vite config, LighterPack URL import proxy, and Vitest config.

## Deployment

The app deploys to GitHub Pages via `.github/workflows/deploy.yml`, which runs
the tests, builds, and publishes on every push to `main`. The Vite `base` is set
to `/ulpacker/` for production builds so asset URLs resolve under the Pages path.

To enable it, set the repository's **Settings → Pages → Source** to
**GitHub Actions**.
