import { useCallback, useEffect, useRef, useState } from "react";
import { requestAccessToken, fetchUserInfo, revokeToken, isConfigured } from "../lib/googleAuth.js";
import { downloadData, uploadData } from "../lib/googleDrive.js";
import { resolveSync } from "../lib/sync.js";

const SIGNED_IN_KEY = "ulpacker.googleSignedIn";
const TOKEN_KEY = "ulpacker.googleToken";
const PROFILE_KEY = "ulpacker.googleProfile";

// Ties Google auth + Drive appDataFolder sync to the app's data.
// - buildData(): returns the current { gears, packs, packItems, updatedAt }
// - applyCloud(cloudData): writes a pulled cloud copy into app state
// - updatedAt: changes whenever local data changes (triggers a debounced push)
export function useGoogleSync({ buildData, applyCloud, updatedAt }) {
  const [account, setAccount] = useState(null);
  const [status, setStatus] = useState("idle"); // idle | syncing | saved | permission | error
  const tokenRef = useRef(null);
  const tokenExpiry = useRef(0);
  const signedInRef = useRef(false);
  const skipNextPush = useRef(false);
  const buildRef = useRef(buildData);
  const applyRef = useRef(applyCloud);
  buildRef.current = buildData;
  applyRef.current = applyCloud;

  // Reuse a cached, still-valid access token so a reload doesn't re-prompt.
  // The token is short-lived (~1h) and limited to the Drive appdata scope.
  const getToken = useCallback(async (interactive) => {
    if (!interactive && tokenRef.current && tokenExpiry.current > Date.now() + 60000) {
      return tokenRef.current;
    }
    const { token, expiresAt } = await requestAccessToken({ prompt: interactive ? "consent" : "" });
    tokenRef.current = token;
    tokenExpiry.current = expiresAt;
    try {
      localStorage.setItem(TOKEN_KEY, JSON.stringify({ token, expiresAt }));
    } catch {
      // ignore storage failures
    }
    return token;
  }, []);

  // Run a Drive call; on failure force a fresh token once and retry.
  // A lingering permission error means the Drive scope wasn't granted.
  const driveCall = useCallback(
    async (fn) => {
      try {
        return await fn(await getToken(false));
      } catch {
        tokenRef.current = null;
        tokenExpiry.current = 0;
        return await fn(await getToken(false));
      }
    },
    [getToken]
  );

  const pull = useCallback(async () => {
    setStatus("syncing");
    try {
      const cloud = await driveCall((token) => downloadData(token));
      const { use, data } = resolveSync(buildRef.current(), cloud);
      if (use === "cloud") {
        // Suppress the debounced push that applying cloud state would trigger.
        // If apply throws (e.g. a quota error while writing the pulled tracks),
        // reset the flag so we don't silently swallow the next real push.
        skipNextPush.current = true;
        try {
          applyRef.current(data);
        } catch (applyError) {
          skipNextPush.current = false;
          throw applyError;
        }
      } else {
        await driveCall((token) => uploadData(token, buildRef.current()));
      }
      setStatus("saved");
    } catch (e) {
      setStatus(e?.code === "permission" ? "permission" : "error");
    }
  }, [driveCall]);

  const signIn = useCallback(async () => {
    setStatus("syncing");
    try {
      const token = await getToken(true);
      const info = await fetchUserInfo(token);
      const profile = { name: info.name, email: info.email, picture: info.picture };
      setAccount(profile);
      signedInRef.current = true;
      localStorage.setItem(SIGNED_IN_KEY, "1");
      try {
        localStorage.setItem(PROFILE_KEY, JSON.stringify(profile));
      } catch {
        // ignore
      }
      await pull();
    } catch {
      setStatus("error");
    }
  }, [getToken, pull]);

  const signOut = useCallback(() => {
    revokeToken(tokenRef.current);
    tokenRef.current = null;
    tokenExpiry.current = 0;
    signedInRef.current = false;
    setAccount(null);
    setStatus("idle");
    localStorage.removeItem(SIGNED_IN_KEY);
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(PROFILE_KEY);
  }, []);

  // Restore the previous session on load (cached profile + token) without a prompt.
  useEffect(() => {
    if (!isConfigured()) return;
    if (localStorage.getItem(SIGNED_IN_KEY) !== "1") return;
    try {
      const profile = JSON.parse(localStorage.getItem(PROFILE_KEY) || "null");
      if (profile) {
        setAccount(profile);
        signedInRef.current = true;
      }
      const cached = JSON.parse(localStorage.getItem(TOKEN_KEY) || "null");
      if (cached?.token && cached.expiresAt > Date.now() + 60000) {
        tokenRef.current = cached.token;
        tokenExpiry.current = cached.expiresAt;
      }
    } catch {
      // ignore corrupt cache
    }
    if (signedInRef.current) pull();
  }, [pull]);

  // Debounced push whenever local data changes.
  useEffect(() => {
    if (!signedInRef.current) return undefined;
    if (skipNextPush.current) {
      skipNextPush.current = false;
      return undefined;
    }
    const timer = setTimeout(async () => {
      setStatus("syncing");
      try {
        await driveCall((token) => uploadData(token, buildRef.current()));
        setStatus("saved");
      } catch (e) {
        setStatus(e?.code === "permission" ? "permission" : "error");
      }
    }, 1500);
    return () => clearTimeout(timer);
  }, [updatedAt, driveCall]);

  return { account, status, configured: isConfigured(), signIn, signOut };
}
