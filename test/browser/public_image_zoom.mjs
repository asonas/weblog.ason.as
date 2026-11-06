import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const port = 15183;
const sizes = { landscape: [2560, 1707], portrait: [1200, 2600] };
const svg = ([width, height], color) => `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}"><rect width="100%" height="100%" fill="${color}"/><rect x="2%" y="2%" width="96%" height="96%" fill="none" stroke="#fff" stroke-width="${width / 60}"/></svg>`;
const html = `<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><link rel="stylesheet" href="/frontend/authoring/publicArticle.css"></head><body>
<style>.site-header{position:fixed;inset:0 0 auto 0;z-index:30;box-sizing:border-box;block-size:72px;background:#fff}body{padding-block-start:72px}</style><header class="site-header"><nav class="header-nav"><a href="/">ason.as</a></nav></header>
<article data-public-article class="e-content ProseMirror public-article-body">
<p>本文です。</p>
<p><span class="article-image"><img src="/assets/landscape.webp" alt="横長の写真" width="2560" height="1707" loading="eager"></span></p>
<p>間の文章です。間の文章です。間の文章です。</p>
<p><span class="article-image"><img src="/assets/portrait.webp" alt="縦長の写真" width="1200" height="2600" loading="eager"></span></p>
<p>後続の文章です。後続の文章です。後続の文章です。</p>
<p>後続の文章です。後続の文章です。後続の文章です。</p>
<p>後続の文章です。後続の文章です。後続の文章です。</p>
</article>
<script type="module" src="/frontend/authoring/publicArticle.ts"></script></body></html>`;

const devices = {
  phone: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, deviceScaleFactor: 2 },
  desktop: { viewport: { width: 1280, height: 900 } },
};

const server = spawn("node_modules/.bin/vite", ["--host", "127.0.0.1", "--port", String(port)], { stdio: ["ignore", "pipe", "pipe"] });
server.stdout.resume();
server.stderr.resume();
let browser;
try {
  for (let i = 0; i < 150; i++) {
    try { if ((await fetch(`http://127.0.0.1:${port}/`)).ok) break; } catch {}
    await setTimeout(100);
  }
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const results = {};
  for (const [device, options] of Object.entries(devices)) {
    const context = await browser.newContext(options);
    const page = await context.newPage();
    await page.route("**/zoom-fixture", route => route.fulfill({ contentType: "text/html", body: html }));
    await page.route("**/assets/*.webp", route => {
      const kind = route.request().url().includes("portrait") ? "portrait" : "landscape";
      return route.fulfill({ contentType: "image/svg+xml", body: svg(sizes[kind], kind === "portrait" ? "#2a6f97" : "#bc6c25") });
    });
    await page.goto(`http://127.0.0.1:${port}/zoom-fixture`);
    await page.locator(".article-image__zoom").nth(1).waitFor();
    await page.waitForFunction(() => [...document.images].every(image => image.complete && image.naturalWidth > 0));
    results[device] = {};
    for (const [index, kind] of ["landscape", "portrait"].entries()) {
      const button = page.locator(".article-image__zoom").nth(index);
      const measure = () => button.evaluate(el => {
        const image = el.querySelector("img").getBoundingClientRect();
        const header = document.querySelector(".site-header").getBoundingClientRect();
        return {
          width: Math.round(image.width * 10) / 10, height: Math.round(image.height * 10) / 10,
          top: Math.round(image.top * 10) / 10, bottom: Math.round(image.bottom * 10) / 10,
          headerBottom: Math.round(header.bottom * 10) / 10,
          viewportWidth: innerWidth, viewportHeight: innerHeight,
          overflowX: document.documentElement.scrollWidth > innerWidth,
        };
      });
      await button.scrollIntoViewIfNeeded();
      const collapsed = await measure();
      await button.click();
      await page.waitForFunction(i => document.querySelectorAll(".article-image__zoom")[i].getAttribute("aria-expanded") === "true", index);
      await page.screenshot({ path: process.env.ZOOM_SCREENSHOTS ? `${process.env.ZOOM_SCREENSHOTS}/${device}-${kind}.png` : undefined });
      const expanded = await measure();
      results[device][kind] = { collapsed, expanded };
      await button.click();
    }
    await context.close();
  }
  if (process.env.ZOOM_RESULTS) writeFileSync(process.env.ZOOM_RESULTS, JSON.stringify(results, null, 2));

  const { phone, desktop } = results;
  const available = (r) => r.viewportHeight - r.headerBottom;
  for (const kind of ["landscape", "portrait"]) {
    const r = phone[kind].expanded;
    assert.equal(r.overflowX, false, `phone ${kind} does not overflow horizontally`);
    assert.ok(r.width <= r.viewportWidth + 0.5, `phone ${kind} fits the screen width`);
    assert.ok(r.height <= available(r) + 0.5, `phone ${kind} fits the available height`);
    assert.ok(Math.abs(r.width / r.height - sizes[kind][0] / sizes[kind][1]) < 0.01, `phone ${kind} keeps its aspect ratio`);
  }
  assert.ok(phone.landscape.expanded.width >= phone.landscape.expanded.viewportWidth - 0.5, "phone landscape uses the full width");
  assert.ok(phone.portrait.expanded.height >= available(phone.portrait.expanded) - 1, "phone portrait uses the full available height");
  for (const kind of ["landscape", "portrait"]) {
    const r = desktop[kind].expanded;
    assert.ok(r.height <= available(r) * 0.75 + 0.5, `desktop ${kind} keeps the 75% height cap`);
  }
  console.log("PASS: phone zoom uses the full width and available height; desktop zoom keeps the 75% cap");
} finally {
  await browser?.close();
  server.kill("SIGTERM");
}
