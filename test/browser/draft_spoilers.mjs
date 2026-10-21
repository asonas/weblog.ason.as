import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const children = [];
const token = crypto.randomUUID();
const source = "前 ||秘密 **強調**|| 後\n\n||![写真](/assets/test.webp)||\n\n||\n[動画](/assets/uploads/2026/10/abc-123.mp4)\n||";
function start(args, env = {}) {
  const child = spawn("mise", ["exec", "--", ...args], {
    env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.resume();
  child.stderr.resume();
  children.push(child);
}
let browser;
try {
  const rendered = spawnSync("mise", ["exec", "--", "ruby", "-rbundler/setup", "-Ilib", "-rweblog_authoring/markdown", "-e", 'puts WeblogAuthoring::MarkdownRenderer.new.render(STDIN.read, mode: "public").html'], { input: source, encoding: "utf8" });
  assert.equal(rendered.status, 0, rendered.stderr);
  start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token, ARTICLE_PIECES_ENABLED: "true" });
  start(["npm", "run", "dev", "--", "--port", "15182"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  let ready = false;
  for (let i = 0; i < 150; i++) {
    try { ready = await (await fetch("http://127.0.0.1:15182/api/draft-test-health")).text() === token; } catch {}
    if (ready) break;
    await setTimeout(100);
  }
  assert.ok(ready);
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.route("**/assets/test.webp", route => route.fulfill({ path: "test/fixtures/article_comparison/assets/rubykaigi-follow-up.webp", contentType: "image/webp" }));
  await page.goto("http://127.0.0.1:15182/draft-editor");
  await page.getByRole("textbox", { name: "タイトル", exact: true }).fill("スポイラーの確認");
  const field = page.getByRole("textbox", { name: "1番目のかけら", exact: true });
  await field.fill(source);
  async function check(root, name) {
    const spoilers = root.locator(".article-spoiler");
    await spoilers.nth(2).waitFor();
    assert.equal(await spoilers.count(), 3);
    for (const index of [0, 1, 2]) {
      const spoiler = spoilers.nth(index);
      const content = spoiler.locator(":scope > .article-spoiler__content");
      const toggle = spoiler.locator(":scope > button");
      assert.equal(await content.evaluate(el => getComputedStyle(el).visibility), "hidden");
      await toggle.click();
      assert.equal(await toggle.getAttribute("aria-expanded"), "true");
      assert.equal(await content.evaluate(el => el.inert), false);
      if (index === 2) {
        await content.locator("video").click({ position: { x: 10, y: 10 } });
        assert.equal(await toggle.getAttribute("aria-expanded"), "true");
        await toggle.click();
      } else {
        await content.click();
      }
      assert.equal(await toggle.getAttribute("aria-expanded"), "false");
      await toggle.focus();
      await page.keyboard.press("Enter");
      assert.equal(await toggle.getAttribute("aria-expanded"), "true");
      await page.keyboard.press("Space");
      assert.equal(await toggle.getAttribute("aria-expanded"), "false");
    }
    for (const width of [1280, 390]) {
      await page.setViewportSize({ width, height: 900 });
      await page.screenshot({ path: `/private/tmp/spoilers-${name}-${width}.png` });
    }
  }
  await check(page.locator(".draft-preview__article"), "preview");
  assert.equal(await field.inputValue(), source);
  await page.route("**/spoiler-fixture", route => route.fulfill({
    contentType: "text/html",
    body: `<!doctype html><meta name="viewport" content="width=device-width"><link rel="stylesheet" href="/frontend/authoring/publicArticle.css"><article data-public-article class="e-content ProseMirror public-article-body" style="max-width:680px;margin:40px auto">${rendered.stdout}</article><script type="module" src="/frontend/authoring/publicArticle.ts"></script>`,
  }));
  await page.goto("http://127.0.0.1:15182/spoiler-fixture");
  await check(page.locator("article"), "public");
  console.log("PASS: public and preview spoilers hide, reveal, re-hide and support keyboard controls; video interaction stays open; Markdown is preserved");
} finally {
  await browser?.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
