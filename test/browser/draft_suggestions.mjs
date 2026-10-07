import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const children = [];
const token = crypto.randomUUID();
function start(args, env = {}) {
  const child = spawn("mise", ["exec", "ruby", "node", "--", ...args], {
    env: { ...process.env, ...env, TYPESAFE_API_KEY: "" },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true,
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
  for (let i = 0; i < 150; i++) {
    if (await check()) return;
    await setTimeout(100);
  }
  assert.fail("Timed out waiting for writing suggestions");
}

let browser;
try {
  const apiLog = start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token, ARTICLE_PIECES_ENABLED: "true" });
  const viteLog = start(["npm", "run", "dev", "--", "--port", "15182"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  await ready("http://127.0.0.1:18082/api/draft-test-health", apiLog);
  await ready("http://127.0.0.1:15182/api/draft-test-health", viteLog);
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.route("**/api/inbox", (route) => route.fulfill({ json: { items: [] } }));
  await page.route("**/api/authoring/proofread", (route) => route.fulfill({ json: { messages: [] } }));
  const requests = [];
  let delayed;
  let shouldDelay = false;
  await page.route("**/api/authoring/suggestions", async (route) => {
    const payload = route.request().postDataJSON();
    requests.push(payload);
    if (shouldDelay) await new Promise((resolve) => { delayed = resolve; });
    const start = payload.text.indexOf("Cloud Flare");
    await route.fulfill({ json: {
      enabled: true,
      links: start < 0 || payload.text.includes("[[Cloudflare]]") ? [] : [{ text: "Cloud Flare", range: [start, start + 11], target: "Cloudflare", title: "Cloudflare", replacement: "[[Cloudflare]]" }],
      related: [{ article_id: "past", title: "以前のキャッシュ設定", target: "以前のキャッシュ設定", url: "/past", date: "2026-08-12", excerpt: "キャッシュを使うと記事の表示が速くなった。".repeat(12), writing_excerpt: payload.text, relation: "repeated" }],
    } });
  });
  const response = await page.request.post("http://127.0.0.1:15182/api/authoring/drafts/daily", { data: { date: "2026-10-07" } });
  assert.equal(response.status(), 200);
  const { id } = await response.json();
  await page.goto(`http://127.0.0.1:15182/draft-editor?id=${id}`);
  const body = page.getByRole("textbox", { name: "1番目のかけら", exact: true });
  const original = "𠮷野でCloud Flareを使った。記事の表示が速くなった。";
  await body.fill(original);
  const panel = page.getByRole("region", { name: "執筆の候補", exact: true });
  const apply = panel.getByRole("button", { name: "1番目のかけら · 1行4文字目 Cloud Flare → [[Cloudflare]]", exact: true });
  await apply.waitFor();
  assert.equal(await body.inputValue(), original);
  assert.equal(requests[0].article_id, id);
  assert.ok(requests[0].piece_id);
  const comparison = panel.locator("details");
  assert.equal(await comparison.getAttribute("open"), null);
  assert.ok((await comparison.boundingBox()).height < 150, "Long excerpts remain collapsed");
  await page.screenshot({ path: "/tmp/weblog-writing-suggestions.png", fullPage: true });
  await comparison.locator("summary").click();
  assert.equal(await panel.getByRole("link", { name: "記事を開く" }).getAttribute("href"), "/past");
  assert.equal(await comparison.locator("blockquote").first().innerText(), original);
  await page.screenshot({ path: "/tmp/weblog-writing-comparison.png", fullPage: true });
  await apply.click();
  assert.equal(await body.inputValue(), "𠮷野で[[Cloudflare]]を使った。記事の表示が速くなった。");
  await body.press("Meta+z");
  assert.equal(await body.inputValue(), original);

  shouldDelay = true;
  await body.fill(`${original}変更前`);
  await until(() => !!delayed);
  await body.fill("別の内容へ変更した。");
  shouldDelay = false;
  delayed();
  await until(async () => await apply.count() === 0);
  assert.equal(await body.inputValue(), "別の内容へ変更した。");

  await body.dispatchEvent("compositionstart");
  const beforeIme = requests.length;
  await body.fill(original);
  await setTimeout(7500);
  assert.equal(requests.length, beforeIme, "Do not send text during IME composition");
  await body.dispatchEvent("compositionend");
  await apply.waitFor();
  await body.evaluate((field) => field.setSelectionRange(field.value.length, field.value.length));
  await comparison.locator("summary").click();
  await panel.getByRole("button", { name: "本文へリンクを挿入", exact: true }).click();
  assert.equal(await body.inputValue(), `${original}[[以前のキャッシュ設定]]`);

  await body.fill("Cloud Flareを使った。\n---\n別のかけら。\n𠮷野でCloud Flareを使った。");
  const secondBody = page.getByRole("textbox", { name: "2番目のかけら", exact: true });
  await secondBody.waitFor();
  const firstCandidate = panel.getByRole("button", { name: "1番目のかけら · 1行1文字目 Cloud Flare → [[Cloudflare]]", exact: true });
  const secondCandidate = panel.getByRole("button", { name: "2番目のかけら · 2行4文字目 Cloud Flare → [[Cloudflare]]", exact: true });
  await firstCandidate.waitFor();
  await secondCandidate.waitFor();
  assert.equal(await secondBody.evaluate((field) => document.activeElement === field), true);
  const beforeApply = requests.length;
  await firstCandidate.click();
  assert.equal(await body.inputValue(), "[[Cloudflare]]を使った。");
  assert.equal(await secondBody.inputValue(), "別のかけら。\n𠮷野でCloud Flareを使った。");
  assert.equal(await body.evaluate((field) => document.activeElement === field), true);
  await until(() => requests.length > beforeApply);
  assert.ok(requests.slice(beforeApply).every((request) => request.piece_id === requests[0].piece_id), "Unchanged pieces reuse their results");
  await secondCandidate.waitFor();
  assert.equal(await firstCandidate.count(), 0, "A link in one piece does not hide another piece's candidate");
  await secondCandidate.click();
  assert.equal(await secondBody.inputValue(), "別のかけら。\n𠮷野で[[Cloudflare]]を使った。");
  await secondBody.press("Meta+z");
  assert.equal(await secondBody.inputValue(), "別のかけら。\n𠮷野でCloud Flareを使った。");
  assert.deepEqual(errors, []);
  console.log("PASS: suggestions cover all pieces with positions, safely activate targets, preserve Undo, cache unchanged pieces, reject stale results, wait for IME and disclose comparisons");
} finally {
  await browser?.close();
  for (const child of children) {
    try { process.kill(-child.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  }
}
