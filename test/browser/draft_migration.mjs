import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const children = [];
const token = crypto.randomUUID();
const origin = "http://127.0.0.1:15182";
const id = "dc802ad0b89946aeb6b7623c2ba7bc79";
function start(args, env = {}) {
  const child = spawn("mise", ["exec", "--", ...args], {
    env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", data => { output += data; });
  child.stderr.on("data", data => { output += data; });
  children.push(child);
  return () => output;
}
let browser;
try {
  const log = start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], {
    DRAFT_TEST_TOKEN: token, DRAFT_TEST_LEGACY_DIARY: "1", ARTICLE_PIECES_ENABLED: "true",
    DRAFT_TEST_LEGACY_BODY: "前半\n---\n後半\n```markdown\n---\n```\n---\n[[金曜日]] [[202610]] [[1002]] [[日記]]",
  });
  start(["npm", "run", "dev", "--", "--port", "15182", "--strictPort"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  let ready = false;
  for (let i = 0; i < 150; i++) {
    try { ready = await (await fetch(`${origin}/api/draft-test-health`)).text() === token; } catch {}
    if (ready) break;
    await setTimeout(100);
  }
  assert.ok(ready, log());
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.route("**/api/auth/session", async route => {
    const response = await route.fetch();
    await route.fulfill({ response, json: { ...await response.json(), piece_authoring: false } });
  });
  await page.goto(`${origin}/draft-editor?id=${id}`);
  const legacy = page.getByRole("textbox", { name: "本文", exact: true });
  await page.waitForFunction(() => document.querySelector('textarea[aria-label="本文"]')?.value.includes("前半"));
  const existing = await legacy.inputValue();
  await page.route(`**/api/authoring/drafts/${id}`, async route => {
    if (route.request().method() === "GET") await route.continue();
    else await route.abort();
  });
  await legacy.fill(existing.replace("前半", "前半の未送信編集"));
  await page.waitForFunction(() => document.querySelector(".draft-editor__sync-status")?.textContent.includes("端末に保存"));
  await page.unroute("**/api/auth/session");
  await page.goto(`${origin}/authoring/articles`);
  await page.unroute(`**/api/authoring/drafts/${id}`);
  const row = page.locator("tbody tr").first();
  await row.getByRole("button", { name: /の操作$/ }).click();
  await page.getByRole("menuitem", { name: "マイグレーションしてから編集", exact: true }).click();
  const first = page.getByRole("textbox", { name: "1番目のかけら", exact: true });
  const second = page.getByRole("textbox", { name: "2番目のかけら", exact: true });
  assert.equal(await first.inputValue(), "前半の未送信編集");
  assert.equal(await second.inputValue(), "後半\n```markdown\n---\n```");
  assert.equal(await page.locator(".draft-piece-editor textarea").count(), 2);
  assert.equal(new URL(page.url()).searchParams.get("id"), id);
  await second.fill("後半の編集");
  await page.waitForFunction(() => document.querySelector(".draft-editor__sync-status")?.textContent.includes("サーバーに保存済み"));
  await page.goto(`${origin}/authoring/articles`);
  await row.getByRole("button", { name: /の操作$/ }).click();
  await page.getByRole("menuitem", { name: "編集", exact: true }).waitFor();
  await page.goto(`${origin}/draft-editor?id=${id}`);
  assert.equal(await second.inputValue(), "後半の編集");
  assert.equal(await page.locator(".draft-piece-editor textarea").count(), 2);
  assert.deepEqual(errors, []);
  console.log("PASS: migration saves unsent legacy edits, opens editable pieces, returns to Edit, and direct URLs preserve migrated content");
} finally {
  await browser?.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
