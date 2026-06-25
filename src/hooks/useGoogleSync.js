import { useCallback, useEffect, useRef, useState } from "react";
import { requestAccessToken, fetchUserInfo, revokeToken, isConfigured } from "../lib/googleAuth.js";
import { downloadData, uploadData } from "../lib/googleDrive.js";
import { resolveSync } from "../lib/sync.js";

const SIGNED_IN_KEY = "ulpacker.googleSignedIn";

// Ties Google auth + Drive appDataFolder sync to the app's data.
// - buildData(): returns the current { gears, packs, packItems, updatedAt }
// - applyCloud(cloudData): writes a pulled cloud copy into app state
// - updatedAt: changes whenever local data changes (triggers a debounced push)
export function useGoogleSync({ buildData, applyCloud, updatedAt }) {
  const [account, setAccount] = useState(null);
  const [status, setStatus] = useState("idle"); // idle | syncing | saved | error
  const tokenRef = useRef(null);
  const signedInRef = useRef(false);
  const skipNextPush = useRef(false);
  const buildRef = useRef(buildData);
  const applyRef = useRef(applyCloud);
  buildRef.current = buildData;
  applyRef.current = applyCloud;

  const getToken = useCallback(async (interactive) => {
    const token = await requestAccessToken({ prompt: interactive ? "consent" : "" });
    tokenRef.current = token;
    return token;
  }, []);

  // Run a Drive call; on failure refresh the token silently once and retry.
  // A lingering permission error means the Drive scope wasn't granted.
  const driveCall = useCallback(
    async (fn) => {
      try {
        const token = tokenRef.current || (await getToken(false));
        return await fn(token);
      } catch {
        const token = await getToken(false);
        return await fn(token);
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
        skipNextPush.current = true;
        applyRef.current(data);
      } else {
        await driveCall((token) => uploadData(token, buildRef.current()));
      }
      setStatus("saved");
    } catch (e) {
      setStatus(e?.code === "permission" ? "permission" : "error");
    }
  }, [driveCall]);

  const enterSignedIn = useCallback(
    async (interactive) => {
      const token = await getToken(interactive);
      const info = await fetchUserInfo(token);
      setAccount({ name: info.name, email: info.email, picture: info.picture });
      signedInRef.current = true;
      localStorage.setItem(SIGNED_IN_KEY, "1");
      await pull();
    },
    [getToken, pull]
  );

  const signIn = useCallback(async () => {
    setStatus("syncing");
    try {
      await enterSignedIn(true);
    } catch {
      setStatus("error");
    }
  }, [enterSignedIn]);

  const signOut = useCallback(() => {
    revokeToken(tokenRef.current);
    tokenRef.current = null;
    signedInRef.current = false;
    setAccount(null);
    setStatus("idle");
    localStorage.removeItem(SIGNED_IN_KEY);
  }, []);

  // Silent re-sign-in on load if the user was signed in before.
  useEffect(() => {
    if (!isConfigured()) return;
    if (localStorage.getItem(SIGNED_IN_KEY) !== "1") return;
    enterSignedIn(false).catch(() => {
      // Stay signed out silently; user can re-authenticate manually.
    });
  }, [enterSignedIn]);

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
