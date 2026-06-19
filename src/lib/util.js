export function id() {
  return typeof crypto !== "undefined" && crypto.randomUUID
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export function parseNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function normalizeWeightType(value) {
  return value === "worn" || value === "consumable" ? value : "base";
}

export function normalizeText(value) {
  return String(value || "").trim().toLowerCase();
}

export function gramsToKg(grams) {
  return `${(grams / 1000).toFixed(2)} kg`;
}

export function textContent(node, fallback = "") {
  return (node?.textContent || fallback).replace(/\s+/g, " ").trim();
}

export function reorder(array, fromIndex, toIndex) {
  if (fromIndex < 0 || toIndex < 0 || fromIndex >= array.length || toIndex >= array.length) {
    return array;
  }
  const next = [...array];
  const [moved] = next.splice(fromIndex, 1);
  next.splice(toIndex, 0, moved);
  return next;
}

export function mutatePackItemsForPack(prev, packId, mutate) {
  const items = prev.filter((item) => item.packId === packId);
  const others = prev.filter((item) => item.packId !== packId);
  return [...others, ...mutate(items)];
}

export function unitToGrams(weight, unit) {
  const normalizedUnit = String(unit || "").toLowerCase().trim();
  const num = parseNumber(weight, 0);
  if (!num) return 0;
  if (normalizedUnit === "g") return num;
  if (normalizedUnit === "kg") return num * 1000;
  if (normalizedUnit === "oz") return num * 28.3495;
  if (normalizedUnit === "lb") return num * 453.592;
  return num;
}
