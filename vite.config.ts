import { fileURLToPath } from "node:url";
import { resolve } from "node:path";
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

const projectRoot = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  plugins: [react()],
  define: {
    "process.env.NODE_ENV": JSON.stringify("production")
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
});
