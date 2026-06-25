import React from "react";
import logoUrl from "../logo.png";

function GoogleGlyph() {
  return (
    <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true">
      <path
        fill="#4285F4"
        d="M23.5 12.27c0-.79-.07-1.54-.2-2.27H12v4.51h6.47a5.53 5.53 0 0 1-2.4 3.63v3h3.88c2.27-2.09 3.55-5.17 3.55-8.87Z"
      />
      <path
        fill="#34A853"
        d="M12 24c3.24 0 5.96-1.08 7.95-2.91l-3.88-3c-1.08.72-2.45 1.16-4.07 1.16-3.13 0-5.78-2.11-6.73-4.96H1.29v3.09A12 12 0 0 0 12 24Z"
      />
      <path
        fill="#FBBC05"
        d="M5.27 14.29A7.2 7.2 0 0 1 4.89 12c0-.8.14-1.57.38-2.29V6.62H1.29A12 12 0 0 0 0 12c0 1.94.46 3.77 1.29 5.38l3.98-3.09Z"
      />
      <path
        fill="#EA4335"
        d="M12 4.75c1.77 0 3.35.61 4.6 1.8l3.43-3.43C17.95 1.18 15.24 0 12 0A12 12 0 0 0 1.29 6.62l3.98 3.09C6.22 6.86 8.87 4.75 12 4.75Z"
      />
    </svg>
  );
}

export default function Landing({ configured, onSignIn, onContinue }) {
  return (
    <div className="landing">
      <div className="landing-card">
        <img className="landing-logo" src={logoUrl} alt="ULPacker" />
        <p className="landing-tagline">
          Build backpacking pack lists with a reusable gear library, weight breakdown, and
          LighterPack import.
        </p>
        <div className="landing-actions">
          {configured && (
            <button type="button" className="google-btn" onClick={onSignIn}>
              <GoogleGlyph />
              Sign in with Google
            </button>
          )}
          <button type="button" className="landing-local" onClick={onContinue}>
            Use without an account
          </button>
        </div>
        <p className="landing-note">
          {configured
            ? "Signing in syncs your packs to your own Google Drive across devices. Without an account, everything stays in this browser."
            : "Your packs are saved in this browser. Google sync is not configured for this build."}
        </p>
      </div>
    </div>
  );
}
