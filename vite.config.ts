import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const projectRoot = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig(({ mode }) => ({
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
          if (route.includes("/") || /[<>\\]/.test(route)) {
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
    "process.env.NODE_ENV": JSON.stringify(mode === "production" ? "production" : "development")
  },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8000",
        changeOrigin: true
      },
      "/assets": {
        target: "http://127.0.0.1:8000",
        changeOrigin: true
      }
    }
  },
  build: {
    lib: {
      entry: resolve(projectRoot, "frontend/authoring/main.tsx"),
      formats: ["iife"],
      name: "WeblogAuthoring",
      fileName: () => "app.js",
      cssFileName: "app"
    },
    outDir: resolve(projectRoot, "static/authoring"),
    emptyOutDir: false,
    rollupOptions: {
      output: {
        assetFileNames: "app.css"
      }
    }
  }
}));
