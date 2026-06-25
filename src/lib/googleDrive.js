// Read/write a single JSON file in the user's private Drive appDataFolder.
// The app can only see this hidden folder, never the user's other files.

const FILE_NAME = "ulpacker.json";
const API = "https://www.googleapis.com/drive/v3";
const UPLOAD = "https://www.googleapis.com/upload/drive/v3";

// 401/403 from Drive usually means the appdata scope wasn't granted.
function permissionError() {
  return Object.assign(new Error("permission"), { code: "permission" });
}

async function findFileId(token) {
  const query = encodeURIComponent(`name='${FILE_NAME}'`);
  const res = await fetch(
    `${API}/files?spaces=appDataFolder&q=${query}&fields=files(id,modifiedTime)&pageSize=1`,
    { headers: { Authorization: `Bearer ${token}` } }
  );
  if (res.status === 401 || res.status === 403) throw permissionError();
  if (!res.ok) throw new Error("Drive list failed");
  const data = await res.json();
  return data.files?.[0]?.id || null;
}

export async function downloadData(token) {
  const id = await findFileId(token);
  if (!id) return null;
  const res = await fetch(`${API}/files/${id}?alt=media`, {
    headers: { Authorization: `Bearer ${token}` }
  });
  if (res.status === 401 || res.status === 403) throw permissionError();
  if (!res.ok) throw new Error("Drive download failed");
  return res.json();
}

export async function uploadData(token, data) {
  const id = await findFileId(token);
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
