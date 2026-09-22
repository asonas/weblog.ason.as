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
  let listRequests = 0;
  await page.route("**/api/authoring/drafts?*", async route => {
    listRequests += 1;
    const cursor = new URL(route.request().url()).searchParams.get("cursor");
    const article = {
      id: cursor ? "pagination-second" : "pagination-first",
      head: 0,
      metadata: { title: cursor ? "2件目" : "1件目", page_type: "named", page_date: "", cover_mode: "auto", cover_image_url: null },
      updated_at: cursor ? "2026-09-19T00:00:00Z" : "2026-09-20T00:00:00Z",
      public_route: null,
      public_hash: null,
      state: "draft",
      publication: null,
    };
    await route.fulfill({ json: { articles: [article], cursor: cursor ? null : "next-page" } });
  });
  await page.goto("http://127.0.0.1:15182/authoring/articles");
  const ledger = page.getByRole("region", { name: "記事一覧", exact: true });
  await page.getByRole("button", { name: "さらに読み込む" }).waitFor();
  assert.equal(listRequests, 1);
  assert.equal(await ledger.locator("tbody tr").count(), 1);
  await page.getByRole("button", { name: "さらに読み込む" }).click();
  await until(async () => await ledger.locator("tbody tr").count() === 2);
  assert.equal(listRequests, 2);
  await page.unroute("**/api/authoring/drafts?*");
  await page.reload();
  const menu = page.getByRole("navigation", { name: "執筆メニュー" });
  await menu.waitFor();
  assert.deepEqual(await menu.locator("a").allTextContents(), ["記事を書く", "記事の管理", "Webmention", "日記を書く", "ホーム"]);
  await menu.getByRole("link", { name: "Webmentionを管理" }).click();
  await page.getByRole("heading", { name: "Webmention", exact: true }).waitFor();
  await page.getByRole("navigation", { name: "執筆メニュー" }).getByRole("link", { name: "記事一覧", exact: true }).click();
  await menu.waitFor();
  const filters = page.getByRole("navigation", { name: "記事の状態" });
  assert.ok(await filters.evaluate((element) => Boolean(element.closest(".draft-admin-ledger"))));
  await page.screenshot({ path: "/tmp/weblog-draft-admin-tabs.png" });
  await page.getByRole("link", { name: "今日の日記を書く", exact: true }).click();
  await page
    .getByRole("link", { name: "記事一覧に戻る", exact: true })
    .waitFor();
  assert.deepEqual(await menu.locator("a").allTextContents(), ["記事一覧へ"]);
  assert.equal(await menu.locator("button").count(), 0);
  const diaryTitle = page.getByLabel("タイトル", { exact: true });
  await diaryTitle.focus();
  assert.equal(
    await diaryTitle.evaluate((element) => getComputedStyle(element).outlineOffset),
    "-3px",
  );
  await page.getByRole("textbox", { name: "本文", exact: true }).fill("今日の日記の本文");
  const diaryDate = await diaryTitle.inputValue();
  await diaryTitle.fill("日付とは別の日記タイトル");
  const diaryId = new URL(page.url()).searchParams.get("id");
  await until(async () => {
    const response = await page.request.get(
      `http://127.0.0.1:15182/api/authoring/drafts/${diaryId}?protocol=1&generation=1&cursor=0`,
    );
    return response.ok() && (await response.json()).metadata.title.value === "日付とは別の日記タイトル";
  });
  const renamedArticle = page.url();
  await page.reload();
  await until(
    async () =>
      (await page.getByLabel("タイトル", { exact: true }).inputValue()) ===
      "日付とは別の日記タイトル",
  );
  await page.getByRole("link", { name: /記事一覧/ }).click();
  await ledger.getByText("日付とは別の日記タイトル", { exact: true }).waitFor();
  assert.ok((await ledger.textContent()).includes("/日付とは別の日記タイトル"));
  await page.getByRole("link", { name: "今日の日記を書く", exact: true }).click();
  await page.getByRole("textbox", { name: "本文", exact: true }).waitFor();
  assert.notEqual(page.url(), renamedArticle);
  await until(async () => await page.getByLabel("タイトル", { exact: true }).inputValue() === diaryDate);
  await page.getByRole("link", { name: /記事一覧/ }).click();
  await page.getByRole("link", { name: "新しい記事を書く", exact: true }).click();
  await page.getByLabel("タイトル", { exact: true }).fill("管理画面の実データ");
  const body = page.getByRole("textbox", { name: "本文", exact: true });
  await body.fill("検索と再開を確認する本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  const article = page.url();
  await page.getByRole("link", { name: /記事一覧/ }).click();
  const search = page.getByRole("searchbox", { name: "タイトルまたはURLで検索" });
  await search.fill("管理画面");
  const detail = ledger.locator("tbody tr").filter({ has: page.getByRole("link", { name: "管理画面の実データ", exact: true }) });
  async function editRow() {
    await detail.getByRole("button", { name: "管理画面の実データの操作", exact: true }).click();
    await page.getByRole("menuitem", { name: "編集", exact: true }).click();
  }
  await until(async () => await ledger.locator("tbody tr").count() === 1);
  await page.screenshot({ path: "/tmp/weblog-170-wide.png" });
  await editRow();
  await until(async () => await body.inputValue() === "検索と再開を確認する本文");
  assert.equal(page.url(), article);
  await fetch("http://127.0.0.1:18082/api/draft-test-search-failure", { method: "POST", headers: { "X-Draft-Test-Token": token } });
  await page.getByRole("button", { name: "公開する", exact: true }).click();
  await until(async () => (await page.getByRole("dialog").getByRole("status").textContent()).includes("公開が完了しました"));
  await page.getByRole("button", { name: "編集を続ける", exact: true }).click();
  await page.getByRole("link", { name: /記事一覧/ }).click();
  await search.fill("管理画面");
  await detail.getByRole("button", { name: "管理画面の実データの操作", exact: true }).click();
  await page.getByRole("menuitem", { name: "公開処理を再試行" }).click();
  await until(async () => (await detail.textContent()).includes("検索：反映済み"));
  assert.ok((await detail.textContent()).includes("公開中"));
  await editRow();
  await page.getByRole("button", { name: "保存する", exact: true }).waitFor();
  assert.equal(await menu.evaluate(element => element.getBoundingClientRect().width), 72);
  assert.equal(await page.locator(".draft-editor").evaluate(element => getComputedStyle(element).backgroundColor), "rgb(247, 247, 244)");
  assert.equal(await page.locator(".draft-preview__document").evaluate(element => getComputedStyle(element).backgroundColor), "rgb(255, 255, 255)");
  await page.screenshot({ path: "/tmp/weblog-authoring-editor-parchment.png" });
  await body.fill("公開後に追記した本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.getByRole("link", { name: /記事一覧/ }).click();
  await page.getByRole("navigation", { name: "記事の状態" }).getByRole("button", { name: "未公開の変更あり" }).click();
  await until(async () => await ledger.locator("tbody tr").count() === 1);
  await editRow();
  await body.fill("検索と再開を確認する本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.getByRole("link", { name: /記事一覧/ }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  await page.getByRole("navigation", { name: "記事の状態" }).getByRole("button", { name: "公開中" }).click();
  await until(async () => await ledger.locator("tbody tr").count() === 1);
  assert.ok((await ledger.textContent()).includes("管理画面の実データ"));
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.screenshot({ path: "/tmp/weblog-170-narrow.png", fullPage: true });
  await editRow();
  await until(async () => await body.inputValue() === "検索と再開を確認する本文");
  await context.setOffline(true);
  await body.fill("端末にだけ保存した本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("端末に保存済み"));
  await page.route("**/api/authoring/drafts/**", route => route.abort());
  await context.setOffline(false);
  await page.getByRole("link", { name: /記事一覧/ }).click();
  await search.fill("管理画面");
  await until(async () => (await detail.textContent()).includes("未送信の変更あり"));
  await editRow();
  await body.fill("検索と再開を確認する本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("端末に保存済み"));
  await page.getByRole("link", { name: /記事一覧/ }).click();
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
  await detail.locator("summary").click();
  await detail.getByText("この公開処理は失効しました。エディタで内容を再確認してください。").waitFor();
  assert.ok(!(await detail.textContent()).includes("処理中"));
  assert.equal(await detail.getByRole("menuitem", { name: "公開処理を再試行" }).count(), 0);
  await page.unroute("**/api/authoring/drafts/**");
  await page.goto(renamedArticle);
  await page.getByRole("button", { name: "公開する", exact: true }).click();
  await until(async () => (await page.getByRole("dialog").getByRole("status").textContent()).includes("公開が完了しました"));
  const publishedArticle = await fetch(
    `http://127.0.0.1:18082/${encodeURIComponent("日付とは別の日記タイトル")}`,
  );
  assert.equal(publishedArticle.status, 200);
  assert.ok((await publishedArticle.text()).includes("今日の日記の本文"));
  await page.getByRole("button", { name: "編集を続ける", exact: true }).click();
  let sentMentions = 0;
  await page.route("**/api/authoring/drafts/*/webmentions", async route => {
    if (route.request().method() === "POST") {
      sentMentions += 1;
      assert.deepEqual(route.request().postDataJSON(), { version_id: "saved-version" });
    }
    await route.fulfill({ json: { version_id: "saved-version", enabled: true, pending: false,
      targets: sentMentions ? [] : ["https://example.net/new"] } });
  });
  await page.getByRole("textbox", { name: "本文", exact: true }).fill("今日の日記の本文\n\n[追加リンク](https://example.net/new)");
  await page.getByRole("button", { name: "保存する", exact: true }).click();
  const sendMention = page.getByRole("dialog").getByRole("button", { name: "Webmentionを送る", exact: true });
  await sendMention.waitFor();
  assert.equal(sentMentions, 0);
  await page.screenshot({ path: "/tmp/weblog-webmention-save-dialog.png" });
  await sendMention.click();
  await page.getByText("Webmentionの送信を受け付けました。", { exact: false }).waitFor();
  assert.equal(sentMentions, 1);
  assert.equal(await sendMention.count(), 0);

  await page.unroute("**/api/authoring/drafts?*");
  const examples = [
    ["日々の記録と、これから書きたいこと", "public", 3],
    ["デスクトップ環境改善計画2026", "unpublished_changes", 2],
    ["2026-09-22", "draft", 0],
    ["小さな道具をつくる楽しみ", "unknown", 1],
    ["とても長い記事タイトルでも途中で切らずに読めるように、日々の工夫と暮らしの記録をまとめる", "public", 0],
  ].map(([title, state, count], index) => ({
    id: `visual-article-${index}`, head: 1,
    metadata: { title, page_type: "named", page_date: "", cover_mode: "auto", cover_image_url: null },
    updated_at: "2026-09-22T13:40:00Z", published_at: state === "draft" ? null : "2026-09-19T11:00:00Z",
    public_route: state === "draft" ? null : title, public_hash: state === "draft" ? null : "published",
    webmention_count: count, state,
    state_error: state === "unknown" ? "公開状態を確認できません。再読み込みしてください。" : null,
    publication: null,
  }));
  await page.route("**/api/authoring/drafts?*", route => route.fulfill({ json: { articles: examples, cursor: null } }));
  await page.setViewportSize({ width: 1440, height: 960 });
  await page.goto("http://127.0.0.1:15182/authoring/articles");
  await ledger.getByRole("link", { name: examples[0].metadata.title, exact: true }).waitFor();
  // Fixture data exercises states and counts; delivery semantics are verified by backend tests.
  const exampleRow = ledger.locator("tbody tr").filter({ has: page.getByRole("link", { name: examples[0].metadata.title, exact: true }) });
  assert.equal(await exampleRow.locator(".draft-admin-mentions").textContent(), "3");
  assert.equal(await exampleRow.locator("time").first().getAttribute("datetime"), "2026-09-19T11:00:00Z");
  const openLink = exampleRow.getByRole("link", { name: /公開記事を開く/ });
  assert.equal(await openLink.getAttribute("target"), "_blank");
  assert.equal(await openLink.getAttribute("href"), `/${encodeURIComponent(examples[0].metadata.title)}`);
  assert.equal(await menu.evaluate(element => element.getBoundingClientRect().width), 224);
  await page.screenshot({ path: "/tmp/weblog-authoring-list-parchment.png", fullPage: true });
  const rowActions = exampleRow.getByRole("button", { name: /の操作/ });
  await rowActions.focus();
  await page.keyboard.press("ArrowDown");
  const editItem = page.getByRole("menuitem", { name: "編集", exact: true });
  await editItem.waitFor();
  assert.equal(await editItem.evaluate(element => element === document.activeElement), true);
  await page.keyboard.press("End");
  await page.screenshot({ path: "/tmp/weblog-authoring-row-menu.png" });
  await page.keyboard.press("Escape");
  assert.equal(await rowActions.evaluate(element => element === document.activeElement), true);
  await rowActions.click();
  await editItem.waitFor();
  await page.getByRole("heading", { name: "記事の管理", exact: true }).click();
  await until(async () => await editItem.count() === 0);
  const contrast = await exampleRow.locator(".draft-admin-title").evaluate(element => {
    const luminance = rgb => rgb.match(/[\d.]+/g).slice(0, 3).map(Number).map(value => value / 255).map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4).reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
    const background = luminance(getComputedStyle(document.querySelector(".draft-admin")).backgroundColor);
    const foreground = luminance(getComputedStyle(element).color);
    return (Math.max(background, foreground) + 0.05) / (Math.min(background, foreground) + 0.05);
  });
  assert.ok(contrast >= 4.5);
  for (const width of [390, 320]) {
    await page.setViewportSize({ width, height: 844 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    await rowActions.click();
    await editItem.waitFor();
    const bounds = await page.getByRole("menu", { name: `${examples[0].metadata.title}の操作` }).boundingBox();
    assert.ok(bounds.x >= 0 && bounds.x + bounds.width <= width);
    await page.keyboard.press("Escape");
    await page.screenshot({ path: `/tmp/weblog-authoring-list-${width}.png`, fullPage: true });
  }
  assert.deepEqual(errors, []);
  console.log("PASS: diary-to-article conversion, create/search/reopen, publication retry, restored published content, wide/narrow layout, local pending summary");
} finally {
  await browser?.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
