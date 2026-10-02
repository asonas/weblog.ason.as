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
async function until(check) {
  for (let i = 0; i < 150; i++) {
    if (await check()) return;
    await setTimeout(100);
  }
  assert.fail("Timed out waiting for cover recovery");
}

let browser;
try {
  start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token });
  start(["npm", "run", "dev", "--", "--port", "15182"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  await until(async () => {
    try { return await (await fetch("http://127.0.0.1:15182/api/draft-test-health")).text() === token; }
    catch { return false; }
  });
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:15182/draft-editor");
  const body = page.getByRole("textbox", { name: "本文", exact: true });
  const original = "保存した本文\n\n![](/assets/cover.webp)";
  const edited = "カバーの保存に失敗しても保持する加筆\n\n![](/assets/cover.webp)";
  await body.fill(original);
  const saved = () => page.locator(".draft-editor__sync-status").textContent();
  await until(async () => (await saved()).includes("サーバーに保存済み"));
  const url = page.url();
  await page.route("**/api/authoring/drafts/*/uploads", async route => {
    const request = route.request().postDataJSON();
    if (request.metadata?.cover_mode?.value === "explicit") {
      await route.fulfill({ status: 422, contentType: "application/json", body: JSON.stringify({ error: "cover_image_url must be a local asset" }) });
    } else await route.continue();
  });
  await page.getByRole("button", { name: "記事の設定", exact: true }).click();
  await page.getByRole("radio", { name: "画像を指定" }).check();
  await page.getByRole("button", { name: "記事の設定を閉じる" }).click();
  await body.fill(edited);
  await until(async () => (await page.locator(".draft-editor__status > [role=alert]").textContent()).includes("カバー設定を保存できません"));
  assert.equal(await body.inputValue(), edited);
  await page.getByRole("button", { name: "記事の設定", exact: true }).click();
  await page.getByRole("radio", { name: "自動" }).check();
  await page.getByRole("button", { name: "記事の設定を閉じる" }).click();
  await until(async () => (await saved()).includes("サーバーに保存済み"));
  await page.reload();
  await until(async () => await body.inputValue() === edited);
  assert.equal(page.url(), url);
  assert.equal(await page.locator("button[title='記事の設定']").count(), 1);
  console.log("PASS: rejected cover metadata can be corrected without losing pending body, changing article ID, or resurrecting the failed request after reload");
} finally {
  await browser?.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
