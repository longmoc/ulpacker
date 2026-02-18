import React, { useEffect, useMemo, useState } from "react";

const STORAGE_KEY = "ulpacker.v1";

const defaultData = {
  gears: [
    {
      id: id(),
      name: "Balo",
      category: "Pack",
      notes: "",
      variants: [
        { id: id(), name: "40L", weight: 920 },
        { id: id(), name: "55L", weight: 1100 }
      ]
    },
    {
      id: id(),
      name: "Áo mưa",
      category: "Clothing",
      notes: "",
      variants: [{ id: id(), name: "Mặc định", weight: 180 }]
    }
  ],
  packItems: []
};

function id() {
  return typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function readStorage() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return defaultData;
    const parsed = JSON.parse(raw);
    if (!parsed || !Array.isArray(parsed.gears) || !Array.isArray(parsed.packItems)) {
      return defaultData;
    }
    const gears = parsed.gears
      .map((gear) => {
        if (!gear || typeof gear !== "object") return null;
        const variants = Array.isArray(gear.variants) && gear.variants.length > 0
          ? gear.variants
              .map((variant) => ({
                id: variant?.id || id(),
                name: variant?.name || "Mặc định",
                weight: Math.max(0, parseNumber(variant?.weight, 0))
              }))
              .filter(Boolean)
          : [{ id: id(), name: "Mặc định", weight: 0 }];
        return {
          id: gear.id || id(),
          name: gear.name || "Unnamed gear",
          category: gear.category || "",
          notes: gear.notes || "",
          variants
        };
      })
      .filter(Boolean);

    const validGearIds = new Set(gears.map((gear) => gear.id));
    const packItems = parsed.packItems
      .map((item) => {
        if (!item || typeof item !== "object" || !validGearIds.has(item.gearId)) return null;
        return {
          id: item.id || id(),
          gearId: item.gearId,
          variantId: item.variantId || "",
          quantity: Math.max(0, parseNumber(item.quantity, 1))
        };
      })
      .filter(Boolean);

    return { gears, packItems };
  } catch {
    return defaultData;
  }
}

function gramsToKg(grams) {
  return `${(grams / 1000).toFixed(2)} kg`;
}

function reorder(array, fromIndex, toIndex) {
  if (toIndex < 0 || toIndex >= array.length) return array;
  const next = [...array];
  const [moved] = next.splice(fromIndex, 1);
  next.splice(toIndex, 0, moved);
  return next;
}

function textContent(node, fallback = "") {
  return (node?.textContent || fallback).replace(/\s+/g, " ").trim();
}

function parseNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function unitToGrams(weight, unit) {
  const normalizedUnit = String(unit || "").toLowerCase().trim();
  const num = parseNumber(weight, 0);
  if (!num) return 0;
  if (normalizedUnit === "g" || normalizedUnit === "gram" || normalizedUnit === "grams") return num;
  if (normalizedUnit === "kg" || normalizedUnit === "kilogram" || normalizedUnit === "kilograms") return num * 1000;
  if (normalizedUnit === "oz" || normalizedUnit === "ounce" || normalizedUnit === "ounces")
    return num * 28.3495;
  if (normalizedUnit === "lb" || normalizedUnit === "lbs" || normalizedUnit === "pound" || normalizedUnit === "pounds")
    return num * 453.592;
  return num;
}

function parseCsvLine(line) {
  const cols = [];
  let current = "";
  let inQuotes = false;
  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"') {
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (char === "," && !inQuotes) {
      cols.push(current.trim());
      current = "";
      continue;
    }
    current += char;
  }
  cols.push(current.trim());
  return cols;
}

function parseLighterpackCsv(text) {
  const lines = text.split(/\r?\n/).filter((line) => line.trim().length > 0);
  if (lines.length < 2) return [];
  const headers = parseCsvLine(lines[0]).map((h) => h.toLowerCase());
  const idx = {
    name: headers.findIndex((h) => h.includes("name") || h.includes("item")),
    category: headers.findIndex((h) => h.includes("category")),
    qty: headers.findIndex((h) => h === "qty" || h.includes("quantity")),
    weight: headers.findIndex((h) => h.includes("weight")),
    unit: headers.findIndex((h) => h.includes("unit")),
    worn: headers.findIndex((h) => h.includes("worn")),
    consumable: headers.findIndex((h) => h.includes("consum"))
  };

  return lines
    .slice(1)
    .map((line) => parseCsvLine(line))
    .map((cols) => {
      const name = (cols[idx.name] || "").trim();
      if (!name) return null;
      const grams = Math.round(unitToGrams(cols[idx.weight], cols[idx.unit]));
      const rawQty = Math.max(0, parseNumber(cols[idx.qty], 1));
      const isWorn = /(yes|true|1)/i.test(cols[idx.worn] || "");
      const isConsumable = /(yes|true|1)/i.test(cols[idx.consumable] || "");
      return {
        name,
        category: (cols[idx.category] || "").trim(),
        grams,
        quantity: isWorn || isConsumable ? 0 : rawQty
      };
    })
    .filter(Boolean);
}

function parseLighterpackHtml(html) {
  const doc = new DOMParser().parseFromString(html, "text/html");
  const title = textContent(doc.querySelector(".lpListName"), "LighterPack");
  const categories = [...doc.querySelectorAll(".lpCategory")];
  const items = categories.flatMap((categoryNode) => {
    const category = textContent(categoryNode.querySelector(".lpCategoryName"), "");
    const rows = [...categoryNode.querySelectorAll(".lpItem")];
    return rows
      .map((row) => {
        const name = textContent(row.querySelector(".lpName"), "");
        if (!name) return null;
        const quantity = Math.max(0, parseNumber(textContent(row.querySelector(".lpQtyCell")), 1));
        const mg = parseNumber(row.querySelector(".lpWeightCell .lpMG")?.value, 0);
        const grams = Math.max(0, Math.round(mg / 1000));
        const isWorn = Boolean(row.querySelector(".lpWorn.lpActive"));
        const isConsumable = Boolean(row.querySelector(".lpConsumable.lpActive"));
        return {
          name,
          category,
          grams,
          quantity: isWorn || isConsumable ? 0 : quantity
        };
      })
      .filter(Boolean);
  });
  return { title, items };
}

export default function App() {
  const initial = readStorage();
  const [gears, setGears] = useState(initial.gears);
  const [packItems, setPackItems] = useState(initial.packItems);
  const [dragOverIndex, setDragOverIndex] = useState(null);
  const [importUrl, setImportUrl] = useState("");
  const [importStatus, setImportStatus] = useState("");
  const [importing, setImporting] = useState(false);
  const [newGear, setNewGear] = useState({
    name: "",
    category: "",
    variantName: "Mặc định",
    variantWeight: ""
  });

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ gears, packItems }));
  }, [gears, packItems]);

  useEffect(() => {
    setPackItems((prev) => {
      let changed = false;
      const next = prev
        .map((item) => {
          const gear = gears.find((g) => g.id === item.gearId);
          if (!gear || gear.variants.length === 0) {
            changed = true;
            return null;
          }
          const variantExists = gear.variants.some((v) => v.id === item.variantId);
          if (!variantExists) {
            changed = true;
            return { ...item, variantId: gear.variants[0].id };
          }
          return item;
        })
        .filter(Boolean);
      return changed ? next : prev;
    });
  }, [gears]);

  const packRows = useMemo(() => {
    return packItems
      .map((item) => {
        const gear = gears.find((g) => g.id === item.gearId);
        if (!gear) return null;
        const variant = gear.variants.find((v) => v.id === item.variantId) || gear.variants[0];
        return {
          ...item,
          gear,
          variant,
          lineWeight: (variant?.weight || 0) * Number(item.quantity || 0)
        };
      })
      .filter(Boolean);
  }, [packItems, gears]);

  const totalWeight = packRows.reduce((sum, row) => sum + row.lineWeight, 0);
  const carriedWeight = packRows
    .filter((row) => Number(row.quantity) > 0)
    .reduce((sum, row) => sum + row.lineWeight, 0);

  function addGear(e) {
    e.preventDefault();
    if (!newGear.name.trim()) return;
    const weight = Number(newGear.variantWeight);
    const gear = {
      id: id(),
      name: newGear.name.trim(),
      category: newGear.category.trim(),
      notes: "",
      variants: [
        {
          id: id(),
          name: newGear.variantName.trim() || "Mặc định",
          weight: Number.isFinite(weight) && weight >= 0 ? weight : 0
        }
      ]
    };
    setGears((prev) => [gear, ...prev]);
    setNewGear({ name: "", category: "", variantName: "Mặc định", variantWeight: "" });
  }

  function updateGear(gearId, patch) {
    setGears((prev) => prev.map((g) => (g.id === gearId ? { ...g, ...patch } : g)));
  }

  function addVariant(gearId) {
    setGears((prev) =>
      prev.map((g) =>
        g.id === gearId
          ? {
              ...g,
              variants: [...g.variants, { id: id(), name: `Biến thể ${g.variants.length + 1}`, weight: 0 }]
            }
          : g
      )
    );
  }

  function updateVariant(gearId, variantId, patch) {
    setGears((prev) =>
      prev.map((g) =>
        g.id === gearId
          ? {
              ...g,
              variants: g.variants.map((v) => (v.id === variantId ? { ...v, ...patch } : v))
            }
          : g
      )
    );
  }

  function removeVariant(gearId, variantId) {
    setGears((prev) =>
      prev.map((g) => {
        if (g.id !== gearId) return g;
        if (g.variants.length <= 1) return g;
        return { ...g, variants: g.variants.filter((v) => v.id !== variantId) };
      })
    );
  }

  function addToPack(gearId, insertIndex = null) {
    const gear = gears.find((g) => g.id === gearId);
    if (!gear || gear.variants.length === 0) return;
    const nextItem = {
      id: id(),
      gearId,
      variantId: gear.variants[0].id,
      quantity: 1
    };
    setPackItems((prev) => {
      if (insertIndex === null || insertIndex > prev.length - 1) {
        return [...prev, nextItem];
      }
      const next = [...prev];
      next.splice(insertIndex, 0, nextItem);
      return next;
    });
  }

  function onPackDrop(e) {
    e.preventDefault();
    const payload = e.dataTransfer.getData("application/json");
    if (!payload) return;
    try {
      const data = JSON.parse(payload);
      if (data.type === "library") {
        addToPack(data.gearId, dragOverIndex);
      }
      if (data.type === "pack") {
        const fromIndex = packItems.findIndex((i) => i.id === data.itemId);
        if (fromIndex === -1 || dragOverIndex === null) return;
        setPackItems((prev) => reorder(prev, fromIndex, dragOverIndex));
      }
    } catch {
      return;
    } finally {
      setDragOverIndex(null);
    }
  }

  function importEntries(entries, sourceLabel) {
    if (!entries.length) {
      setImportStatus("Không tìm thấy gear hợp lệ để import.");
      return;
    }

    const nextGears = gears.map((gear) => ({ ...gear, variants: [...gear.variants] }));
    const importedPackItems = [];

    for (const entry of entries) {
      const name = (entry.name || "").trim();
      if (!name) continue;

      const category = (entry.category || "").trim();
      const grams = Math.max(0, Math.round(parseNumber(entry.grams, 0)));
      const quantity = Math.max(0, parseNumber(entry.quantity, 1));

      let gear = nextGears.find(
        (g) => g.name.trim().toLowerCase() === name.toLowerCase() && (g.category || "") === category
      );

      if (!gear) {
        gear = {
          id: id(),
          name,
          category,
          notes: sourceLabel || "",
          variants: [{ id: id(), name: "Imported", weight: grams }]
        };
        nextGears.push(gear);
      }

      let variant = gear.variants.find((v) => Math.round(v.weight) === grams);
      if (!variant) {
        variant = { id: id(), name: `Imported ${gear.variants.length + 1}`, weight: grams };
        gear.variants = [...gear.variants, variant];
      }

      importedPackItems.push({
        id: id(),
        gearId: gear.id,
        variantId: variant.id,
        quantity
      });
    }

    setGears(nextGears);
    setPackItems((prev) => [...prev, ...importedPackItems]);
    setImportStatus(`Đã import ${importedPackItems.length} items từ ${sourceLabel || "source"}.`);
  }

  async function handleImportUrl(e) {
    e.preventDefault();
    if (!importUrl.trim()) return;
    setImporting(true);
    setImportStatus("");
    try {
      const query = new URLSearchParams({ url: importUrl.trim() });
      const response = await fetch(`/api/lighterpack?${query.toString()}`);
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(payload?.error || "Không fetch được URL.");
      }
      const parsed = parseLighterpackHtml(payload.html || "");
      importEntries(parsed.items, parsed.title);
    } catch (error) {
      setImportStatus(error.message || "Import URL thất bại.");
    } finally {
      setImporting(false);
    }
  }

  async function handleImportCsv(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    try {
      const text = await file.text();
      const entries = parseLighterpackCsv(text);
      importEntries(entries, `CSV: ${file.name}`);
    } catch {
      setImportStatus("Không đọc được file CSV.");
    } finally {
      e.target.value = "";
    }
  }

  return (
    <div className="app">
      <header>
        <h1>ULPacker</h1>
        <p>Lưu toàn bộ gear theo thư viện, kéo-thả vào danh sách mang theo, quantity = 0 để tạm không mang.</p>
      </header>

      <main className="layout">
        <section className="panel">
          <h2>Thư viện gear</h2>
          <div className="import-box">
            <form className="import-url-form" onSubmit={handleImportUrl}>
              <input
                placeholder="https://lighterpack.com/r/..."
                value={importUrl}
                onChange={(e) => setImportUrl(e.target.value)}
              />
              <button type="submit" disabled={importing}>
                {importing ? "Đang import..." : "Import URL"}
              </button>
              <label className="file-label">
                Import CSV
                <input type="file" accept=".csv,text/csv" onChange={handleImportCsv} />
              </label>
            </form>
            {importStatus && <p className="import-status">{importStatus}</p>}
          </div>

          <form className="add-gear-form" onSubmit={addGear}>
            <input
              placeholder="Tên gear"
              value={newGear.name}
              onChange={(e) => setNewGear((v) => ({ ...v, name: e.target.value }))}
            />
            <input
              placeholder="Category"
              value={newGear.category}
              onChange={(e) => setNewGear((v) => ({ ...v, category: e.target.value }))}
            />
            <input
              placeholder="Variant mặc định"
              value={newGear.variantName}
              onChange={(e) => setNewGear((v) => ({ ...v, variantName: e.target.value }))}
            />
            <input
              type="number"
              min="0"
              placeholder="Weight (gram)"
              value={newGear.variantWeight}
              onChange={(e) => setNewGear((v) => ({ ...v, variantWeight: e.target.value }))}
            />
            <button type="submit">Thêm gear</button>
          </form>

          <div className="gear-list">
            {gears.map((gear) => (
              <article
                key={gear.id}
                className="gear-card"
                draggable
                onDragStart={(e) =>
                  e.dataTransfer.setData(
                    "application/json",
                    JSON.stringify({ type: "library", gearId: gear.id })
                  )
                }
              >
                <div className="card-top">
                  <input
                    className="name"
                    value={gear.name}
                    onChange={(e) => updateGear(gear.id, { name: e.target.value })}
                  />
                  <input
                    className="category"
                    value={gear.category}
                    onChange={(e) => updateGear(gear.id, { category: e.target.value })}
                    placeholder="Category"
                  />
                </div>

                <div className="variant-list">
                  {gear.variants.map((variant) => (
                    <div className="variant-row" key={variant.id}>
                      <input
                        value={variant.name}
                        onChange={(e) => updateVariant(gear.id, variant.id, { name: e.target.value })}
                      />
                      <input
                        type="number"
                        min="0"
                        value={variant.weight}
                        onChange={(e) =>
                          updateVariant(gear.id, variant.id, {
                            weight: Math.max(0, Number(e.target.value || 0))
                          })
                        }
                      />
                      <span>g</span>
                      <button
                        type="button"
                        disabled={gear.variants.length <= 1}
                        onClick={() => removeVariant(gear.id, variant.id)}
                      >
                        Xóa
                      </button>
                    </div>
                  ))}
                </div>

                <div className="card-actions">
                  <button type="button" onClick={() => addVariant(gear.id)}>
                    + Variant
                  </button>
                  <button type="button" onClick={() => addToPack(gear.id)}>
                    Thêm vào pack
                  </button>
                </div>
              </article>
            ))}
          </div>
        </section>

        <section
          className="panel dropzone"
          onDragOver={(e) => e.preventDefault()}
          onDrop={onPackDrop}
        >
          <h2>Pack list (kéo gear từ trái qua)</h2>
          <div className="weight-cards">
            <div>
              <small>Tổng hiện có trong list</small>
              <strong>{gramsToKg(totalWeight)}</strong>
            </div>
            <div>
              <small>Đang mang (quantity &gt; 0)</small>
              <strong>{gramsToKg(carriedWeight)}</strong>
            </div>
          </div>

          <div className="pack-list">
            {packRows.length === 0 && <p className="hint">Chưa có gear trong pack list.</p>}
            {packRows.map((row, index) => (
              <div
                key={row.id}
                className={`pack-row ${dragOverIndex === index ? "drag-over" : ""} ${
                  Number(row.quantity) === 0 ? "inactive" : ""
                }`}
                draggable
                onDragStart={(e) =>
                  e.dataTransfer.setData(
                    "application/json",
                    JSON.stringify({ type: "pack", itemId: row.id })
                  )
                }
                onDragOver={(e) => {
                  e.preventDefault();
                  setDragOverIndex(index);
                }}
              >
                <div className="pack-main">
                  <strong>{row.gear.name}</strong>
                  <small>{row.gear.category || "Uncategorized"}</small>
                </div>
                <select
                  value={row.variant.id}
                  onChange={(e) =>
                    setPackItems((prev) =>
                      prev.map((item) =>
                        item.id === row.id ? { ...item, variantId: e.target.value } : item
                      )
                    )
                  }
                >
                  {row.gear.variants.map((v) => (
                    <option key={v.id} value={v.id}>
                      {v.name} ({v.weight}g)
                    </option>
                  ))}
                </select>
                <input
                  type="number"
                  min="0"
                  value={row.quantity}
                  onChange={(e) =>
                    setPackItems((prev) =>
                      prev.map((item) =>
                        item.id === row.id
                          ? { ...item, quantity: Math.max(0, Number(e.target.value || 0)) }
                          : item
                      )
                    )
                  }
                />
                <div className="line-weight">{gramsToKg(row.lineWeight)}</div>
                <button
                  type="button"
                  onClick={() => setPackItems((prev) => prev.filter((item) => item.id !== row.id))}
                >
                  Bỏ khỏi list
                </button>
              </div>
            ))}
          </div>
        </section>
      </main>
    </div>
  );
}
