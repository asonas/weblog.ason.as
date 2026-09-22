import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const fixture = JSON.parse(await readFile(new URL("../fixtures/home_comparison/home.json", import.meta.url), "utf8"));
const photo = await readFile(new URL("../fixtures/article_comparison/assets/rubykaigi-follow-up.webp", import.meta.url));
const server = spawn("mise", ["exec", "--", "npm", "run", "dev", "--", "--port", "15185"], { stdio: ["ignore", "pipe", "pipe"] });
let output = "";
server.stdout.on("data", data => { output += data; });
server.stderr.on("data", data => { output += data; });
let browser;
try {
  for (let attempt = 0; !output.includes("http://127.0.0.1:15185/"); attempt++) {
    if (attempt > 100 || server.exitCode !== null) throw new Error(output);
    await setTimeout(100);
  }
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.route("**/api/**", async route => {
    const path = new URL(route.request().url()).pathname;
    const payload = { "/api/pages": fixture.api.pages, "/api/tags": fixture.api.tags, "/api/archive": fixture.api.archive, "/api/auth/session": fixture.api.auth }[path] ?? {};
    await route.fulfill({ json: payload });
  });
  await page.route("**/assets/**", async route => {
    if (new URL(route.request().url()).pathname.startsWith("/assets/previews/")) {
      await route.fulfill({ status: 404, body: "Not Found" });
    } else {
      await route.fulfill({ contentType: "image/webp", body: photo });
    }
  });
  await page.goto("http://127.0.0.1:15185/", { waitUntil: "networkidle" });
  for (const width of [1440, 500, 390, 1440, 500]) {
    await page.setViewportSize({ width, height: 900 });
    await page.waitForFunction(() => {
      const image = document.querySelector(".cover-journal__photo img");
      return image?.complete && image.naturalWidth > 0 && !image.currentSrc.includes("/previews/");
    }, null, { timeout: 3000 });
    const visible = await page.locator(".cover-journal__photo img").boundingBox();
    assert.ok(visible && visible.width === width && visible.height > 0);
  }
  console.log("Hero survives desktop-to-mobile resize when previews return 404");
} finally {
  await browser?.close();
  server.kill("SIGTERM");
}
