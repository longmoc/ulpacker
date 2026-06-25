// Pure helpers for last-write-wins sync between local and cloud copies.

export function dataUpdatedAt(data) {
  const t = Date.parse(data?.updatedAt || "");
  return Number.isFinite(t) ? t : 0;
}

// Decide which copy wins. Returns { use: "local" | "cloud", data }.
// - No cloud yet -> use local (will be pushed up).
// - No local -> use cloud.
// - Otherwise the newer updatedAt wins; ties keep local (avoids needless pulls).
export function resolveSync(local, cloud) {
  if (!cloud) return { use: "local", data: local };
  if (!local) return { use: "cloud", data: cloud };
  return dataUpdatedAt(cloud) > dataUpdatedAt(local)
    ? { use: "cloud", data: cloud }
    : { use: "local", data: local };
}
