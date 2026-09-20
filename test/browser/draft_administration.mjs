import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const children = [];
const token = crypto.randomUUID();
function start(args, env = {}) {
  const child = spawn("mise", ["exec", "--", ...args], { env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
  let output = "";
  child.stdout.on("data", data => { output += data; });
  child.stderr.on("data", data => { output += data; });
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
  for (let i = 0; i < 200; i++) { if (await check()) return; await setTimeout(100); }
  assert.fail("Timed out waiting for article state");
}
let browser;
try {
  const apiLog = start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token, DRAFT_TEST_LEGACY_DIARY: "1" });
  const viteLog = start(["node", "node_modules/vite/bin/vite.js", "--port", "15182"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  await ready("http://127.0.0.1:18082/api/draft-test-health", apiLog);
  await ready("http://127.0.0.1:15182/api/draft-test-health", viteLog);
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 960 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto("http://127.0.0.1:15182/authoring/articles");
  await page.getByRole("button", { name: "今日の日記を書く", exact: true }).click();
  await page.getByRole("textbox", { name: "本文", exact: true }).fill("今日の日記の本文");
  await page.getByText("記事とカバーの設定", { exact: true }).click();
  const diaryDate = await page.getByLabel("日記の日付（URL）", { exact: true }).inputValue();
  await page.getByLabel("タイトル", { exact: true }).fill("日付とは別の日記タイトル");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  const diary = page.url();
  await page.reload();
  await page.getByText("記事とカバーの設定", { exact: true }).click();
  assert.equal(await page.getByLabel("日記の日付（URL）", { exact: true }).inputValue(), diaryDate);
  assert.equal(await page.getByLabel("タイトル", { exact: true }).inputValue(), "日付とは別の日記タイトル");
  await page.getByRole("link", { name: "記事一覧", exact: true }).click();
  await page.getByRole("button", { name: "今日の日記を書く", exact: true }).click();
  await page.getByRole("textbox", { name: "本文", exact: true }).waitFor();
  assert.equal(page.url(), diary);
  assert.equal(await page.getByRole("textbox", { name: "本文", exact: true }).inputValue(), "今日の日記の本文");
  await page.getByRole("link", { name: "記事一覧", exact: true }).click();
  await page.getByRole("button", { name: "日記以外の記事を書く", exact: true }).click();
  await page.getByLabel("タイトル", { exact: true }).fill("管理画面の実データ");
  const body = page.getByRole("textbox", { name: "本文", exact: true });
  await body.fill("検索と再開を確認する本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  const article = page.url();
  await page.getByRole("link", { name: "記事一覧", exact: true }).click();
  const search = page.getByRole("searchbox", { name: "タイトルまたはURLで検索" });
  await search.fill("管理画面");
  const ledger = page.getByRole("region", { name: "記事一覧", exact: true });
  const detail = page.getByRole("region", { name: "選択した記事", exact: true });
  await until(async () => await ledger.locator("li").count() === 1);
  await page.screenshot({ path: "/tmp/weblog-170-wide.png" });
  await detail.getByRole("link", { name: "編集・公開内容を確認" }).click();
  await until(async () => await body.inputValue() === "検索と再開を確認する本文");
  assert.equal(page.url(), article);
  await fetch("http://127.0.0.1:18082/api/draft-test-search-failure", { method: "POST", headers: { "X-Draft-Test-Token": token } });
  await page.getByRole("button", { name: "公開", exact: true }).click();
  await page.getByRole("button", { name: "この内容で公開", exact: true }).click();
  await until(async () => (await page.getByRole("status").textContent()).includes("公開が完了しました"));
  await page.getByRole("link", { name: "記事一覧", exact: true }).click();
  await search.fill("管理画面");
  await detail.getByRole("button", { name: "公開処理を再試行" }).click();
  await until(async () => (await detail.textContent()).includes("検索：反映済み"));
  assert.ok((await detail.textContent()).includes("公開中"));
  await detail.getByRole("link", { name: "編集・公開内容を確認" }).click();
  await body.fill("公開後に追記した本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.getByRole("link", { name: "記事一覧", exact: true }).click();
  await page.getByRole("navigation", { name: "記事の状態" }).getByRole("button", { name: "未公開の変更あり" }).click();
  await until(async () => await ledger.locator("li").count() === 1);
  await detail.getByRole("link", { name: "編集・公開内容を確認" }).click();
  await body.fill("検索と再開を確認する本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.getByRole("link", { name: "記事一覧", exact: true }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("navigation", { name: "記事の状態" }).getByRole("button", { name: "公開中" }).click();
  await until(async () => await ledger.locator("li").count() === 1);
  assert.ok((await ledger.textContent()).includes("管理画面の実データ"));
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.screenshot({ path: "/tmp/weblog-170-narrow.png", fullPage: true });
  await detail.getByRole("link", { name: "編集・公開内容を確認" }).click();
  await until(async () => await body.inputValue() === "検索と再開を確認する本文");
  await context.setOffline(true);
  await body.fill("端末にだけ保存した本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("端末に保存済み"));
  await page.route("**/api/authoring/drafts/**", route => route.abort());
  await context.setOffline(false);
  await page.getByRole("link", { name: "記事一覧", exact: true }).click();
  await search.fill("管理画面");
  await until(async () => (await detail.textContent()).includes("未送信の変更あり"));
  await detail.getByRole("link", { name: "編集・公開内容を確認" }).click();
  await body.fill("検索と再開を確認する本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("端末に保存済み"));
  await page.getByRole("link", { name: "記事一覧", exact: true }).click();
  await search.fill("管理画面");
  await until(async () => (await detail.textContent()).includes("未送信の変更あり"));
  assert.ok((await detail.textContent()).includes("公開中"), "local content equal to the published hash stays public despite pending CRDT updates");
  await page.route("**/api/authoring/drafts?*", async route => {
    const response = await route.fetch();
    const data = await response.json();
    const row = data.articles.find(row => row.id === new URL(article).searchParams.get("id"));
    row.publication.status = "superseded";
    for (const stage of row.publication.stages) stage.status = "superseded";
    await route.fulfill({ response, json: data });
  });
  await page.getByRole("button", { name: "再読み込み", exact: true }).click();
  await detail.getByText("この公開処理は失効しました。エディタで内容を再確認してください。").waitFor();
  assert.ok(!(await detail.textContent()).includes("処理中"));
  assert.equal(await detail.getByRole("button", { name: "公開処理を再試行" }).count(), 0);
  await page.unroute("**/api/authoring/drafts/**");
  await page.goto(diary);
  await page.getByRole("button", { name: "公開", exact: true }).click();
  await page.getByRole("button", { name: "この内容で公開", exact: true }).click();
  await until(async () => (await page.getByRole("status").textContent()).includes("公開が完了しました"));
  const publishedDiary = await fetch(`http://127.0.0.1:18082/${diaryDate}`);
  assert.equal(publishedDiary.status, 200);
  assert.ok((await publishedDiary.text()).includes("日付とは別の日記タイトル"));
  assert.deepEqual(errors, []);
  console.log("PASS: daily reuse, create/search/reopen, publication retry, restored published content, wide/narrow layout, local pending summary");
} finally {
  await browser?.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
