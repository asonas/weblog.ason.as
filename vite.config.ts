import { fileURLToPath } from "node:url";
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
      name: "reject-unsafe-page-routes",
      configureServer(server) {
        server.middlewares.use((request, response, next) => {
          if (!request.headers.accept?.includes("text/html") || !request.url) return next();

          let pathname: string;
          try {
            pathname = decodeURIComponent(new URL(request.url, "http://127.0.0.1").pathname);
          } catch (_error) {
            response.statusCode = 400;
            response.end("Bad Request");
            return;
          }

          if (pathname === "/api" || pathname.startsWith("/api/") || pathname.startsWith("/assets/")) {
            return next();
          }

          const route = pathname.slice(1).replace(/\/$/, "");
          const isEditorRoute = /^\/editor\/[^/]+\/?$/.test(pathname);
          if ((!isEditorRoute && route.includes("/")) || /[<>\\]/.test(route)) {
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
  }
}));
