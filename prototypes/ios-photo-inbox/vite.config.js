import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const root = fileURLToPath(new URL(".", import.meta.url));

export default defineConfig({
  root,
  server: {
    host: "127.0.0.1",
    port: 5174,
    strictPort: true
  },
  build: {
    outDir: "dist",
    emptyOutDir: true
  }
});
