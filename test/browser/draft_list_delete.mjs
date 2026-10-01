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
  assert.fail("Timed out waiting for draft deletion");
}
let browser;
try {
  start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token, DRAFT_TEST_LEGACY_DIARY: "1", ARTICLE_PIECES_ENABLED: "true" });
  start(["npm", "run", "dev", "--", "--port", "15182"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  await until(async () => {
    try { return await (await fetch("http://127.0.0.1:15182/api/draft-test-health")).text() === token; }
    catch { return false; }
  });
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:15182/draft-editor");
  await page.getByRole("textbox", { name: "タイトル", exact: true }).fill("一覧から削除するかけら記事");
  await page.getByRole("textbox", { name: "1番目のかけら", exact: true }).fill("保存する本文");
  await until(async () => (await page.locator(".draft-editor__sync-status").textContent()).includes("サーバーに保存済み"));
  const id = new URL(page.url()).searchParams.get("id");
  await page.goto("http://127.0.0.1:15182/authoring/articles");
  let accept = false;
  page.on("dialog", async dialog => {
    assert.ok(dialog.message().includes("取り消せません"));
    await (accept ? dialog.accept() : dialog.dismiss());
  });
  const row = page.locator("tbody tr").filter({ hasText: "一覧から削除するかけら記事" });
  await row.getByRole("button", { name: "一覧から削除するかけら記事の操作" }).click();
  await page.getByRole("menuitem", { name: "削除", exact: true }).click();
  await row.waitFor();
  accept = true;
  await row.getByRole("button", { name: "一覧から削除するかけら記事の操作" }).press("ArrowUp");
  await page.getByRole("menuitem", { name: "削除", exact: true }).press("Enter");
  await row.waitFor({ state: "detached" });
  assert.equal(await page.evaluate(async id => (await fetch(`/api/authoring/drafts/${id}?format=auto`)).status, id), 404);
  await page.reload();
  assert.equal(await row.count(), 0);
  const legacyRow = page.locator("tbody tr").filter({ has: page.locator('a[href*="dc802ad0b89946aeb6b7623c2ba7bc79"]') });
  await legacyRow.getByRole("button", { name: /の操作$/ }).click();
  await page.getByRole("menuitem", { name: "削除", exact: true }).click();
  await legacyRow.waitFor({ state: "detached" });
  assert.equal(await page.getByRole("alert").count(), 0);
  console.log("PASS: draft list deletion confirms or cancels, supports keyboard activation, removes local and server drafts, and supports legacy drafts");
} finally {
  await browser?.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
