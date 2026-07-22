// Read/write a single JSON file in the user's private Drive appDataFolder.
// The app can only see this hidden folder, never the user's other files.

// v4 uses a NEW Drive file. An old client build only ever reads/writes the v3
// file, so it can never pull-then-push the v4 bundle and strip Trips. On first
// v4 sync we fall back to reading the v3 file once (migration); we never write
// back to it.
const FILE_NAME = "ulpacker-v4.json";
const LEGACY_FILE_NAME_V3 = "ulpacker.json";
const API = "https://www.googleapis.com/drive/v3";
const UPLOAD = "https://www.googleapis.com/upload/drive/v3";

// 401/403 from Drive usually means the appdata scope wasn't granted.
function permissionError() {
  return Object.assign(new Error("permission"), { code: "permission" });
}

async function findFileId(token, name = FILE_NAME) {
  const query = encodeURIComponent(`name='${name}'`);
  const res = await fetch(
    `${API}/files?spaces=appDataFolder&q=${query}&fields=files(id,modifiedTime)&pageSize=1`,
    { headers: { Authorization: `Bearer ${token}` } }
  );
  if (res.status === 401 || res.status === 403) throw permissionError();
  if (!res.ok) throw new Error("Drive list failed");
  const data = await res.json();
  return data.files?.[0]?.id || null;
}

async function fetchContent(token, id) {
  const res = await fetch(`${API}/files/${id}?alt=media`, {
    headers: { Authorization: `Bearer ${token}` }
  });
  if (res.status === 401 || res.status === 403) throw permissionError();
  if (!res.ok) throw new Error("Drive download failed");
  return res.json();
}

export async function downloadData(token) {
  const v4Id = await findFileId(token, FILE_NAME);
  if (v4Id) return fetchContent(token, v4Id);
  // Migration: read the legacy v3 file once; the app normalizes it and the next
  // push creates the v4 file (leaving v3 untouched for rollback).
  const v3Id = await findFileId(token, LEGACY_FILE_NAME_V3);
  if (v3Id) return fetchContent(token, v3Id);
  return null;
}

export async function uploadData(token, data) {
  const id = await findFileId(token, FILE_NAME);
  const body = JSON.stringify(data);

  if (id) {
    const res = await fetch(`${UPLOAD}/files/${id}?uploadType=media`, {
      method: "PATCH",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body
    });
    if (res.status === 401 || res.status === 403) throw permissionError();
    if (!res.ok) throw new Error("Drive update failed");
    return id;
  }

  const boundary = `ulpacker-${Math.random().toString(16).slice(2)}`;
  const metadata = { name: FILE_NAME, parents: ["appDataFolder"] };
  const multipart =
    `--${boundary}\r\n` +
    "Content-Type: application/json; charset=UTF-8\r\n\r\n" +
    `${JSON.stringify(metadata)}\r\n` +
    `--${boundary}\r\n` +
    "Content-Type: application/json\r\n\r\n" +
    `${body}\r\n` +
    `--${boundary}--`;

  const res = await fetch(`${UPLOAD}/files?uploadType=multipart&fields=id`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": `multipart/related; boundary=${boundary}`
    },
    body: multipart
  });
  if (res.status === 401 || res.status === 403) throw permissionError();
  if (!res.ok) throw new Error("Drive create failed");
  const created = await res.json();
  return created.id;
}
