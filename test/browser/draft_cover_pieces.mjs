import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const children = [];
const token = crypto.randomUUID();
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
  start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token, ARTICLE_PIECES_ENABLED: "true" });
  start(["npm", "run", "dev", "--", "--port", "15182"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  let ready = false;
  for (let i = 0; i < 150; i++) {
    try { ready = await (await fetch("http://127.0.0.1:15182/api/draft-test-health")).text() === token; } catch {}
    if (ready) break;
    await setTimeout(100);
  }
  assert.ok(ready, "Isolated test server is ready");
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:15182/draft-editor");
  const title = page.getByRole("textbox", { name: "タイトル", exact: true });
  await title.waitFor();
  await page.evaluate(() => { document.documentElement.dataset.environment = "production"; });
  await title.fill("タイトル確認");
  await title.fill("");
  await page.waitForFunction(() => document.title === "weblog.ason.as");
  await title.fill("テストの記事です。");
  await page.waitForFunction(() => document.title === "テストの記事です。 | weblog.ason.as");
  await page.evaluate(() => { document.documentElement.dataset.environment = "development"; });
  await title.fill("2026-09-22");
  await page.waitForFunction(() => document.title === "[dev] 2026-09-22 | weblog.ason.as");
  const first = page.getByRole("textbox", { name: "1番目のかけら", exact: true });
  await first.fill("![first](/assets/first.webp)");
  await page.waitForFunction(() => document.querySelector(".draft-preview__article .article-reading-header img")?.getAttribute("src") === "/assets/first.webp");
  assert.equal(await page.locator(".draft-preview__article .article-reading-header h1").textContent(), "2026-09-22");
  await first.press("End");
  await first.press("Enter");
  await first.press("Enter");
  await first.pressSequentially("---");
  await first.press("Enter");
  await first.pressSequentially("s");
  await page.getByRole("textbox", { name: "2番目のかけら", exact: true }).fill("![second](/assets/second.webp)\n\n![duplicate](/assets/first.webp)\n\n```markdown\n![code](/assets/code.webp)\n```");
  const open = page.getByRole("button", { name: "カバー設定", exact: true });
  await open.click();
  assert.equal(await page.getByAltText("選択中のカバー").getAttribute("src"), "/assets/first.webp");
  await page.getByRole("radio", { name: "画像を指定" }).check();
  const choices = page.locator(".draft-cover-settings__choice img");
  assert.deepEqual(await choices.evaluateAll(images => images.map(image => image.getAttribute("src"))), ["/assets/first.webp", "/assets/second.webp"]);
  await page.getByRole("button", { name: "カバー設定を閉じる" }).click();
  await first.click();
  await open.click();
  assert.deepEqual(await choices.evaluateAll(images => images.map(image => image.getAttribute("src"))), ["/assets/first.webp", "/assets/second.webp"]);
  assert.equal(await page.getByText("選択中のカバーは本文にありません。", { exact: false }).count(), 0);
  await page.getByRole("button", { name: "カバー設定を閉じる" }).click();
  for (const index of [2, 3]) {
    const field = page.getByRole("textbox", { name: `${index}番目のかけら`, exact: true });
    await field.fill(`${index}番目の本文\n\n---\n新しいかけら`);
    await page.getByRole("textbox", { name: `${index + 1}番目のかけら`, exact: true }).waitFor();
  }
  const third = page.getByRole("textbox", { name: "3番目のかけら", exact: true });
  await third.fill("3番目のかけらの加筆");
  await page.waitForFunction(() => document.querySelector(".draft-editor__sync-status")?.textContent.includes("サーバーに保存済み"));
  await page.reload();
  await page.getByRole("textbox", { name: "4番目のかけら", exact: true }).waitFor();
  assert.equal(await page.locator(".draft-piece-editor textarea").count(), 4);
  assert.equal(await third.inputValue(), "3番目のかけらの加筆");
  console.log("PASS: cover candidates include all pieces in article order, deduplicate images, exclude code, and remain unchanged when changing the active piece");
  console.log("PASS: a named article displays four editable pieces and preserves later-piece edits after reload");
} finally {
  await browser?.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
