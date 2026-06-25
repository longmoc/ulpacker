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

  const pull = useCallback(async () => {
    setStatus("syncing");
    try {
      const token = tokenRef.current || (await getToken(false));
      const cloud = await downloadData(token);
      const { use, data } = resolveSync(buildRef.current(), cloud);
      if (use === "cloud") {
        skipNextPush.current = true;
        applyRef.current(data);
      } else {
        await uploadData(token, buildRef.current());
      }
      setStatus("saved");
    } catch {
      setStatus("error");
    }
  }, [getToken]);

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
      const attempt = async () => {
        const token = tokenRef.current || (await getToken(false));
        await uploadData(token, buildRef.current());
      };
      try {
        await attempt();
        setStatus("saved");
      } catch {
        try {
          await getToken(false);
          await attempt();
          setStatus("saved");
        } catch {
          setStatus("error");
        }
      }
    }, 1500);
    return () => clearTimeout(timer);
  }, [updatedAt, getToken]);

  return { account, status, configured: isConfigured(), signIn, signOut };
}
