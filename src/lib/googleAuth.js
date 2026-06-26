// Thin wrapper around Google Identity Services (client-side OAuth token flow).
// No client secret is used; the public client id is read from the build env.

const GIS_SRC = "https://accounts.google.com/gsi/client";
export const SCOPES = "openid email profile https://www.googleapis.com/auth/drive.appdata";

let gisPromise = null;

function loadGis() {
  if (typeof window !== "undefined" && window.google?.accounts?.oauth2) return Promise.resolve();
  if (gisPromise) return gisPromise;
  gisPromise = new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = GIS_SRC;
    script.async = true;
    script.defer = true;
    script.onload = () => resolve();
    script.onerror = () => reject(new Error("Failed to load Google Identity Services"));
    document.head.appendChild(script);
  });
  return gisPromise;
}

export function getClientId() {
  return import.meta.env.VITE_GOOGLE_CLIENT_ID || "";
}

export function isConfigured() {
  return Boolean(getClientId());
}

// Requests an access token. `prompt: ""` is silent after the first consent;
// `prompt: "consent"` forces the interactive popup.
export async function requestAccessToken({ prompt = "" } = {}) {
  await loadGis();
  const clientId = getClientId();
  if (!clientId) throw new Error("Missing VITE_GOOGLE_CLIENT_ID");
  return new Promise((resolve, reject) => {
    const client = window.google.accounts.oauth2.initTokenClient({
      client_id: clientId,
      scope: SCOPES,
      prompt,
      callback: (response) => {
        if (response.error) reject(new Error(response.error));
        else
          resolve({
            token: response.access_token,
            expiresAt: Date.now() + (Number(response.expires_in) || 3600) * 1000
          });
      },
      error_callback: (err) => reject(new Error(err?.type || "oauth_error"))
    });
    client.requestAccessToken();
  });
}

export async function fetchUserInfo(token) {
  const res = await fetch("https://www.googleapis.com/oauth2/v3/userinfo", {
    headers: { Authorization: `Bearer ${token}` }
  });
  if (!res.ok) throw new Error("Failed to fetch user info");
  return res.json();
}

export function revokeToken(token) {
  if (token && typeof window !== "undefined" && window.google?.accounts?.oauth2) {
    window.google.accounts.oauth2.revoke(token, () => {});
  }
}
