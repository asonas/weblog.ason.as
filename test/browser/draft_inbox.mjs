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
async function until(check, message) {
  for (let index = 0; index < 100; index++) {
    if (await check()) return;
    await setTimeout(100);
  }
  assert.fail(message);
}
async function ready(url, log) {
  await until(async () => {
    try { return await (await fetch(url)).text() === token; }
    catch { return false; }
  }, `Server did not start: ${log()}`);
}

let browser;
try {
  const apiLog = start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token });
  const viteLog = start(["npm", "run", "dev", "--", "--port", "15182", "--strictPort"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  await ready("http://127.0.0.1:18082/api/draft-test-health", apiLog);
  await ready("http://127.0.0.1:15182/api/draft-test-health", viteLog);
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage();
  const now = new Date("2026-10-19T12:00:00Z");
  await page.clock.setFixedTime(now);
  let items = [];
  await page.route("**/api/inbox", (route) => route.fulfill({
    contentType: "application/json", body: JSON.stringify({ items }),
  }));
  await page.route("**/api/page-names", (route) => route.fulfill({
    contentType: "application/json", body: '{"names":[]}',
  }));
  await page.route("**/api/inbox/memos", route => route.fulfill({ json: { memos: [] } }));
  await page.goto("http://127.0.0.1:15182/draft-editor");
  const inbox = page.getByRole("region", { name: "素材", exact: true });
  await page.getByRole("textbox", { name: "本文", exact: true }).waitFor();
  const video = inbox.getByRole("region", { name: "動画", exact: true });
  assert.equal(await video.count(), 0, "Empty video column must be hidden");
  for (const label of ["写真", "Raindrop", "Bsky（自分の投稿）", "Bsky（いいね）"]) {
    assert.equal(await inbox.getByRole("region", { name: label, exact: true }).count(), 0);
  }
  items = [{ id: "video-1", source: "video", kind: "video", ingested_at: new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString(), payload: { avc: "/assets/uploads/inbox-video.mp4" } }];
  await page.evaluate(() => window.dispatchEvent(new Event("draft-video-uploaded")));
  await video.waitFor();
  assert.equal(await video.getByRole("button", { name: "動画を本文へ追加", exact: true }).count(), 1);
  await page.clock.setFixedTime(new Date(now.getTime() + 1));
  await video.getByRole("button", { name: "動画を再読み込み", exact: true }).click();
  const expand = video.getByRole("button", { name: "動画を開く", exact: true });
  await expand.waitFor();
  assert.ok((await video.boundingBox()).width <= 44);
  assert.equal(await video.getByRole("button", { name: "動画を本文へ追加", exact: true }).count(), 0);
  for (const width of [1280, 390]) {
    await page.setViewportSize({ width, height: 900 });
    assert.ok((await video.boundingBox()).width <= 44);
    await page.screenshot({ path: `/private/tmp/draft-inbox-collapsed-${width}.png` });
  }
  await expand.focus();
  await expand.press("Enter");
  await video.getByRole("button", { name: "動画を本文へ追加", exact: true }).waitFor();
  const collapse = video.getByRole("button", { name: "動画を折りたたむ", exact: true });
  await collapse.press("Space");
  await expand.waitFor();
  items.push({ ...items[0], id: "video-2", ingested_at: now.toISOString() });
  await page.evaluate(() => window.dispatchEvent(new Event("draft-video-uploaded")));
  await collapse.waitFor();
  assert.equal(await video.getByRole("button", { name: "動画を本文へ追加", exact: true }).count(), 2);
  items = [];
  await video.getByRole("button", { name: "動画を再読み込み", exact: true }).click();
  await until(async () => await video.count() === 0, "Video column remained after count became zero");
  console.log("PASS: empty columns hide; videos expand through seven days, collapse after seven days, reopen by keyboard, and expand when a recent video arrives");
} finally {
  await browser?.close();
  for (const child of children) child.kill("SIGTERM");
}
