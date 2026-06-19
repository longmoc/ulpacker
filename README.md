# ULPacker

ULPacker is a local-first React app for building backpacking pack lists with a reusable gear library. It borrows the fast pack-list workflow from LighterPack and the pack/library split from PackWizard, while keeping items around even when their pack quantity is `0`.

## Features

- Manage multiple packs from the `Packs` view.
- Keep reusable gear in a separate `Gear Library` view.
- Add library gear into any pack, not only the currently active pack.
- Group pack items by category with editable category headings.
- Add items directly inside each category group.
- Get semi-auto-fill suggestions from the gear library while typing a pack item name.
- Drag gear from the library into a pack list.
- Drag pack rows to reorder items.
- Keep pack item quantity at `0` without deleting the underlying gear.
- Mark each pack item as `Base`, `Consumable`, or `Worn`; only one special flag can be active at once.
- Edit item weight directly in the pack list.
- Visualize carried weight with a donut chart, category percentages, and total/base/consumable/worn breakdown.
- Import from LighterPack by URL or CSV.

## Gear Library

Library gear stores the reusable product-level data:

- `name`: product name.
- `itemType`: type such as `Tent`, `Backpack`, or `Fresh Food`.
- `description`: extra product details.
- `categories`: multiple categories per gear item, edited as chips.
- `variants`: named weight options in grams.

The app currently seeds an `Egg` item into the library:

- Name: `Egg`
- Item type: `Fresh Food`
- Category: `Food`
- Variant: `Default`, `58g`
- Note: EU medium egg class midpoint estimate.

Deleting gear from the library also removes pack items that reference that gear.

## Pack Items

A pack item references one library gear item, but can still keep pack-specific values:

- Category used in that pack.
- Quantity.
- Current weight in grams.
- Weight type: `base`, `consumable`, or `worn`.
- Variant reference when selected from a multi-variant library item.

This means the same gear can exist in the library once, then appear in different packs or categories with pack-specific quantities and flags.

## Import

Open `Import Pack` from the pack page to import from:

- A public `lighterpack.com` URL.
- A LighterPack CSV export.

URL import uses the local Vite proxy endpoint in `vite.config.js` so the browser can fetch LighterPack HTML during development/preview. The proxy only allows `lighterpack.com` and `www.lighterpack.com`.

Import mapping options:

- `Name -> Name, Description -> Description`
- `Description -> Name, Name -> Item Type`
- Optional item type autofill from category.
- Optional description field from detected variant text.

Imported gear is merged into the library and added to the active pack.

## Merge And Migration

The library merge key is:

```text
name + itemType
```

The comparison is case-insensitive and trimmed.

When adding or importing gear:

- Missing categories are appended into `categories`.
- New non-zero weights become variants when that weight is not already present.
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

There is no backend database yet. Data is browser-local unless exported or copied manually.

## Tech Stack

- React 18
- Vite 5
- Plain CSS
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

Build production assets:

```bash
npm run build
```

Preview the production build:

```bash
npm run preview
```

## Main Files

- `src/App.jsx`: app state, data model, migration, import parsing, and UI.
- `src/styles.css`: app styling.
- `vite.config.js`: LighterPack URL import proxy.
