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
    }
  ]
}));
