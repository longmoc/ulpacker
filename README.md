# ULPacker

ULPacker is a React app for managing backpacking gear and packs, inspired by LighterPack/PackWizard workflows.

## Highlights

- Multiple packs (`Packs` view) with per-pack item lists.
- Gear library (`Gear Library` view) shared across all packs.
- Gear supports:
  - Multiple categories (`categories: string[]`)
  - Item type, description
  - Variants (weight options)
- Pack items support:
  - Quantity
  - Editable weight
  - Weight type: Base / Consumable / Worn
- Drag & drop reorder in pack item list.
- Category-grouped pack table with quick add + suggestions from library.
- Donut chart + breakdown (Total / Base / Consumable / Worn) with hover tooltip.
- LighterPack import:
  - URL import (via local Vite proxy endpoint)
  - CSV import
  - Configurable mapping options

## Merge Logic (Library Model)

When adding/importing gear, app merges existing items by:

- `name` + `itemType` (case-insensitive, trimmed)

Merge behavior:

- New category is appended into `categories` if missing.
- New non-zero weight is added as variant if not already present.
- Zero-weight variants are removed when any non-zero variant exists.
- Keep a single zero variant only when all variants are zero.

On app load, stored data is migrated/normalized and duplicate gears are merged automatically.

## Tech Stack

- React 18
- Vite 5
- Plain CSS
- LocalStorage persistence

## Run Locally

```bash
npm install
npm run dev
```

Build production:

```bash
npm run build
npm run preview
```

## Main Files

- `src/App.jsx`: app logic + UI
- `src/styles.css`: styles
- `vite.config.js`: LighterPack URL proxy for dev/preview

## Notes

- Data is stored in browser `localStorage` under app storage key.
- Deleting a gear from library also removes related pack items.
