import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { resolve, sep } from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const projectRoot = fileURLToPath(new URL(".", import.meta.url));
const authoringApiOrigin = process.env.AUTHORING_API_ORIGIN || "http://127.0.0.1:8000";
const isLinkedWorktree = projectRoot.includes(`${sep}.worktrees${sep}`);
const nestedWorktrees = `${resolve(projectRoot, ".worktrees")}${sep}`;

export default defineConfig(({ mode }) => ({
  base: "/",
  plugins: [
    {
      name: "draft-offline-shell",
      apply: "build",
      generateBundle: { order: "post", handler(_options, bundle) {
        const files = Object.values(bundle).filter((file) =>
          file.fileName === "index.html" || /\.(js|css)$/.test(file.fileName)
        );
        const version = createHash("sha256");
        for (const file of files) version.update(file.type === "chunk" ? file.code : file.source);
        const assets = files.map((file) => `/${file.fileName}`);
        this.emitFile({
          type: "asset",
          fileName: "draft-offline.js",
          source: `
const CACHE = ${JSON.stringify(`draft-shell-${version.digest("hex")}`)};
const ASSETS = ${JSON.stringify(assets)};
self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(ASSETS)));
});
self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name.startsWith("draft-shell-") && name !== CACHE) await caches.delete(name);
    }
    await self.clients.claim();
  })());
});
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== self.location.origin) return;
  const key = event.request.mode === "navigate" && url.pathname === "/draft-editor"
    ? "/index.html" : ASSETS.includes(url.pathname) ? url.pathname : null;
  if (!key) return;
  event.respondWith((async () => {
    const cached = await (await caches.open(CACHE)).match(key);
    return cached || fetch(event.request);
  })());
});`,
        });
      } },
    },
    {
      name: "reject-unsafe-page-routes",
      configureServer(server) {
        server.middlewares.use((request, response, next) => {
          if (!request.headers.accept?.includes("text/html") || !request.url) return next();

          let pathname: string;
          let rawPathname: string;
          try {
            rawPathname = new URL(request.url, "http://127.0.0.1").pathname;
            pathname = decodeURIComponent(rawPathname);
          } catch (_error) {
            response.statusCode = 400;
            response.end("Bad Request");
            return;
          }

          if (pathname === "/api" || pathname.startsWith("/api/") || pathname.startsWith("/assets/")) {
            return next();
          }

          const route = rawPathname.slice(1).replace(/\/$/, "");
          if (mode !== "production" && rawPathname === "/authoring/articles") return next();
          const isEditorRoute = /^\/editor\/[^/]+\/?$/.test(rawPathname);
          if ((!isEditorRoute && route.includes("/")) || /[<>\\]/.test(pathname)) {
            response.statusCode = 404;
            response.end("Not Found");
            return;
          }
          next();
        });
      }
    },
    react()
  ],
  define: {
    "process.env.NODE_ENV": JSON.stringify(mode === "production" ? "production" : "development"),
    __BUILD_SHA__: JSON.stringify(process.env.GITHUB_SHA || "development"),
    __DEPLOYMENT_ENVIRONMENT__: JSON.stringify(mode)
  },
  optimizeDeps: {
    exclude: ["@jsquash/webp", "@jsquash/webp/encode"]
  },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    watch: {
      ignored: (path) => path.startsWith(nestedWorktrees),
      usePolling: isLinkedWorktree,
      interval: 150
    },
    proxy: {
      "/feed.xml": {
        target: authoringApiOrigin
      },
      "/api": {
        target: authoringApiOrigin
      },
      "/assets": {
        target: authoringApiOrigin
      }
    }
  },
  build: {
    outDir: resolve(projectRoot, "dist/site"),
    assetsDir: "static/authoring/assets",
    chunkSizeWarningLimit: 800,
    emptyOutDir: true,
    rollupOptions: {
      input: { index: resolve(projectRoot, "index.html"), public: resolve(projectRoot, "public.html"), notFound: resolve(projectRoot, "404.html") },
      output: {
        entryFileNames: (chunk) => chunk.name === "index" ? "static/authoring/app.js" : "static/authoring/assets/[name]-[hash].js",
        chunkFileNames: "static/authoring/assets/[name]-[hash].js",
        assetFileNames: (assetInfo) =>
          assetInfo.names.some((name) => name === "index.css")
            ? "static/authoring/app.css"
            : "static/authoring/assets/[name]-[hash][extname]",
      },
    },
  }
}));
