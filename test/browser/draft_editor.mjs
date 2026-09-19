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
  let output = "";
  child.stdout.on("data", (data) => { output += data; });
  child.stderr.on("data", (data) => { output += data; });
  children.push(child);
  return () => output;
}
async function ready(url, log) {
  for (let i = 0; i < 100; i++) {
    try { if (await (await fetch(url)).text() === token) return; } catch {}
    await setTimeout(100);
  }
  throw new Error(`Server did not start: ${log()}`);
}
async function until(check) {
  for (let i = 0; i < 100; i++) { if (await check()) return; await setTimeout(100); }
  assert.fail("Timed out waiting for saved state");
}

let browser;
try {
  const apiLog = start(["ruby", "-S", "bundle", "exec", "ruby", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token });
  const viteLog = start(["node", "node_modules/vite/bin/vite.js", "--port", "15182"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  await ready("http://127.0.0.1:18082/api/draft-test-health", apiLog);
  await ready("http://127.0.0.1:15182/api/draft-test-health", viteLog);
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto("http://127.0.0.1:15182/draft-editor");
  await page.getByLabel("タイトル", { exact: true }).fill("保存と公開は別");
  const body = page.getByRole("textbox", { name: "本文", exact: true });
  await body.fill("# 日本語の下書き\n\nclass User\nend\n");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  const url = page.url();
  await page.reload();
  await until(async () => await body.inputValue() === "# 日本語の下書き\n\nclass User\nend\n");
  assert.equal(await page.getByLabel("タイトル", { exact: true }).inputValue(), "保存と公開は別");

  // A new browser context has no IndexedDB data; recovery must use the API.
  const other = await browser.newContext();
  const reopened = await other.newPage();
  await reopened.goto(url);
  await until(async () => await reopened.getByRole("textbox", { name: "本文", exact: true }).inputValue() === "# 日本語の下書き\n\nclass User\nend\n");
  assert.equal(await reopened.getByLabel("タイトル", { exact: true }).inputValue(), "保存と公開は別");
  await other.close();

  await body.press("End");
  await body.pressSequentially("local undo");
  await body.press("Meta+z");
  assert.ok(!(await body.inputValue()).includes("local undo"));
  await body.press("Meta+Shift+z");
  assert.ok((await body.inputValue()).includes("local undo"));

  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let received = false;
  await page.route("**/updates", async (route) => {
    const response = await route.fetch();
    received = true;
    await held;
    await route.fulfill({ response });
  }, { times: 1 });
  await body.fill("保存の応答を待っている本文");
  await until(() => received);
  assert.ok((await page.getByRole("status").textContent()).includes("端末に保存済み"));
  assert.ok(!(await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await body.fill("保存の応答を待つ間に追記した本文");
  await setTimeout(1200);
  release();
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  const fresh = await browser.newContext();
  const freshPage = await fresh.newPage();
  await freshPage.goto(url);
  await until(async () => await freshPage.getByRole("textbox", { name: "本文", exact: true }).inputValue() === "保存の応答を待つ間に追記した本文");
  await fresh.close();

  await body.fill("あ".repeat(174_763));
  await until(async () => (await page.getByRole("alert").textContent()).includes("512 KiB"));
  assert.equal((await body.inputValue()).length, 174_763);
  await page.reload();
  await until(async () => (await body.inputValue()).length === 174_763);
  const publicPages = await (await fetch("http://127.0.0.1:18082/api/pages")).json();
  assert.deepEqual(publicPages.pages, []);
  assert.deepEqual(errors, []);
  console.log("PASS: API and IndexedDB reopen, native textarea Undo/Redo, oversized text retention, public isolation");
} finally {
  await browser?.close();
  for (const child of children) child.kill("SIGTERM");
}
