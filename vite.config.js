import { defineConfig } from "vite";

function isAllowedLighterpackHost(hostname) {
  return hostname === "lighterpack.com" || hostname === "www.lighterpack.com";
}

function lighterpackProxyMiddleware() {
  return async (req, res, next) => {
    try {
      if (!req.url?.startsWith("/api/lighterpack")) {
        next();
        return;
      }

      const requestUrl = new URL(req.url, "http://localhost");
      const target = requestUrl.searchParams.get("url");
      if (!target) {
        res.statusCode = 400;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ error: "Missing url query param." }));
        return;
      }

      let parsed;
      try {
        parsed = new URL(target);
      } catch {
        res.statusCode = 400;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ error: "Invalid URL." }));
        return;
      }

      if (!["http:", "https:"].includes(parsed.protocol) || !isAllowedLighterpackHost(parsed.hostname)) {
        res.statusCode = 400;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ error: "Only lighterpack.com URLs are allowed." }));
        return;
      }

      const upstream = await fetch(parsed.toString(), {
        headers: {
          "user-agent": "ULPacker importer"
        }
      });

      if (!upstream.ok) {
        res.statusCode = upstream.status;
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify({ error: `Fetch failed (${upstream.status}).` }));
        return;
      }

      const html = await upstream.text();
      res.statusCode = 200;
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify({ html }));
    } catch (error) {
      res.statusCode = 500;
      res.setHeader("Content-Type", "application/json");
      res.end(JSON.stringify({ error: error?.message || "Unexpected server error." }));
    }
  };
}

// Service worker source. `__PRECACHE__` and `__VERSION__` are substituted at
// build time with the real emitted filenames, so a new build can never be served
// half-old: the cache name changes and the previous one is dropped outright.
const SW_SOURCE = `
const VERSION = "__VERSION__";
const CACHE = "ulpacker-" + VERSION;
const PRECACHE = __PRECACHE__;

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(PRECACHE)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// The document is network-first so a deploy is picked up as soon as there is a
// connection, and falls back to the cached shell when there isn't. Everything
// else we precache is content-hashed, so cache-first is safe and instant.
self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  const sameOrigin = url.origin === self.location.origin;

  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(INDEX, copy));
          return res;
        })
        .catch(() => caches.match(INDEX).then((hit) => hit || Response.error()))
    );
    return;
  }

  // Google Fonts: cache on first success so the offline shell keeps its type.
  const isFont =
    url.host === "fonts.googleapis.com" || url.host === "fonts.gstatic.com";

  if (!sameOrigin && !isFont) return;

  event.respondWith(
    caches.match(req).then(
      (hit) =>
        hit ||
        fetch(req)
          .then((res) => {
            if (res.ok || res.type === "opaque") {
              const copy = res.clone();
              caches.open(CACHE).then((c) => c.put(req, copy));
            }
            return res;
          })
          .catch(() => hit)
    )
  );
});
`;

export default defineConfig(({ command }) => ({
  // GitHub Pages serves the site under /<repo>/, so built asset URLs need that
  // prefix. Local dev/preview stays at "/" so the import proxy keeps working.
  base: command === "build" ? "/ulpacker/" : "/",
  test: {
    environment: "node"
  },
  plugins: [
    {
      name: "lighterpack-import-proxy",
      configureServer(server) {
        server.middlewares.use(lighterpackProxyMiddleware());
      },
      configurePreviewServer(server) {
        server.middlewares.use(lighterpackProxyMiddleware());
      }
    },
    {
      // Content-Security-Policy as a meta tag, injected at BUILD time only
      // (GitHub Pages can't set headers; in dev Vite injects inline scripts
      // for HMR/React refresh which a static CSP would block).
      // Allows: our own bundle, the Google Identity Services script/iframes,
      // Google APIs (userinfo + Drive appdata), Google avatar images, inline
      // styles (React style attributes) and data: images (pack covers).
      name: "csp-meta",
      apply: "build",
      transformIndexHtml() {
        const csp = [
          "default-src 'self'",
          "script-src 'self' https://accounts.google.com",
          "connect-src 'self' https://www.googleapis.com https://oauth2.googleapis.com https://accounts.google.com",
          "img-src 'self' data: https://*.googleusercontent.com https://*.tile.openstreetmap.org https://*.tile.opentopomap.org",
          "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
          "font-src 'self' https://fonts.gstatic.com",
          "frame-src https://accounts.google.com",
          "object-src 'none'",
          "base-uri 'self'",
          "form-action 'self'"
        ].join("; ");
        return [
          {
            tag: "meta",
            attrs: { "http-equiv": "Content-Security-Policy", content: csp },
            injectTo: "head-prepend"
          }
        ];
      }
    },
    {
      // Offline shell. Emits sw.js listing the exact files this build produced,
      // so the app opens with no connection at all — the trips and packs it
      // reads live in localStorage, which never needed the network anyway.
      name: "offline-sw",
      apply: "build",
      generateBundle(_options, bundle) {
        const base = "/ulpacker/";
        const assets = Object.keys(bundle)
          .filter((name) => !name.endsWith(".map"))
          .map((name) => base + name);
        // Static files copied from public/ aren't in the bundle — list them.
        const statics = [
          "favicon.png",
          "apple-touch-icon.png",
          "icon-512.png",
          "manifest.webmanifest"
        ].map((name) => base + name);
        const precache = [base, ...assets, ...statics];
        const version = Date.now().toString(36);
        const code =
          `const INDEX = ${JSON.stringify(base)};\n` +
          SW_SOURCE.replace("__VERSION__", version).replace(
            "__PRECACHE__",
            JSON.stringify([...new Set(precache)], null, 2)
          );
        this.emitFile({ type: "asset", fileName: "sw.js", source: code });
      }
    }
  ]
}));
