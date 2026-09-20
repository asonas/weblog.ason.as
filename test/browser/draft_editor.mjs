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
  const apiLog = start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token });
  const viteLog = start(["node", "node_modules/vite/bin/vite.js", "--port", "15182"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  await ready("http://127.0.0.1:18082/api/draft-test-health", apiLog);
  await ready("http://127.0.0.1:15182/api/draft-test-health", viteLog);
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage();
  await page.route(/\/assets\/.*\.webp$/, (route) => route.fulfill({
    path: "test/fixtures/article_comparison/assets/rubykaigi-follow-up.webp",
    contentType: "image/webp",
  }));
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  const inboxItems = [
    ...Array.from({ length: 8 }, (_, index) => ({
      id: index === 0 ? "photo-ok" : index === 1 ? "photo-fail" : `photo-${index}`,
      source: "photo",
      kind: "photo",
      payload: { preview_url: `/assets/inbox/photo-${index}.webp` },
    })),
    {
      id: "video-1",
      source: "video",
      kind: "video",
      payload: {
        avc: "/assets/uploads/2026/09/00000000-0000-4000-8000-000000000001.mp4",
        width: 1280,
        height: 720,
      },
    },
    {
      id: "raindrop-1",
      source: "raindrop",
      kind: "bookmark",
      payload: {
        url: "https://example.com/bookmark",
        title: "読みたい記事",
        excerpt: "あとで読むための説明",
      },
    },
    {
      id: "bluesky-1",
      source: "bluesky",
      kind: "post",
      payload: {
        canonical_url: "https://bsky.app/profile/example.test/post/123",
        author_display_name: "書いた人",
        text: "投稿の本文",
      },
    },
  ];
  await page.route("**/api/inbox", async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ items: inboxItems }),
    });
  });
  await page.route("**/api/inbox/adopt", async (route) => {
    const { item_id: itemId } = route.request().postDataJSON();
    if (itemId === "photo-fail") {
      await route.fulfill({
        status: 503,
        contentType: "application/json",
        body: JSON.stringify({ error: "写真を採用できませんでした" }),
      });
      return;
    }
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ public_url: `/assets/uploads/2026/09/${itemId}.webp` }),
    });
  });
  let inboxSyncSource;
  await page.route("**/api/inbox/sync", async (route) => {
    [inboxSyncSource] = route.request().postDataJSON().sources;
    await route.fulfill({
      status: 202,
      contentType: "application/json",
      body: JSON.stringify({ run_id: "draft-inbox-sync", status: "queued" }),
    });
  });
  await page.route("**/api/inbox/sync/draft-inbox-sync", async (route) => {
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ id: "draft-inbox-sync", status: "succeeded" }),
    });
  });
  const legacyId = "dc802ad0b89946aeb6b7623c2ba7bc79";
  const created = await page.request.put(`http://127.0.0.1:15182/api/authoring/drafts/${legacyId}`, {
    data: { protocol: 1, generation: 1 },
  });
  assert.equal(created.status(), 200);
  await page.goto(`http://127.0.0.1:15182/draft-editor?id=${legacyId}`);
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

  const inbox = page.getByRole("region", { name: "素材" });
  for (const label of ["写真", "動画", "Raindrop", "Bluesky"])
    assert.equal(await inbox.getByRole("region", { name: label }).count(), 1);
  const photoColumn = inbox.getByRole("region", { name: "写真" });
  assert.ok(
    await photoColumn.locator("ol").evaluate((list) => list.scrollHeight > list.clientHeight),
    "each inbox column must have its own vertical scroll",
  );
  assert.ok(!(await photoColumn.textContent()).includes("photo-ok"));
  assert.ok(!(await photoColumn.textContent()).includes("挿入"));
  await inbox
    .getByRole("region", { name: "Raindrop" })
    .getByRole("button", { name: "Raindropを再読み込み" })
    .click();
  await until(() => inboxSyncSource === "raindrop");
  await until(async () => await inbox.getByRole("button", { name: "Raindropを再読み込み" }).isEnabled());

  await body.fill("前半\n\n後半");
  await body.evaluate((field) => field.setSelectionRange(4, 4));
  await inbox
    .getByRole("region", { name: "Raindrop" })
    .getByRole("button", { name: "Raindropを本文へ追加" })
    .click();
  assert.equal(await body.inputValue(), "前半\n\nhttps://example.com/bookmark\n\n後半");
  await body.press("Meta+z");
  assert.equal(await body.inputValue(), "前半\n\n後半");

  await body.fill("写真の前\n\n写真の後");
  await body.evaluate((field) => field.setSelectionRange(6, 6));
  await photoColumn.getByRole("button", { name: "写真を本文へ追加" }).nth(0).click();
  await until(async () => (await body.inputValue()).includes("photo-ok.webp"));
  assert.equal(
    await body.inputValue(),
    "写真の前\n\n![](/assets/uploads/2026/09/photo-ok.webp)\n\n写真の後",
  );
  const beforeFailedAdoption = await body.inputValue();
  await photoColumn.getByRole("button", { name: "写真を本文へ追加" }).nth(1).click();
  await inbox.getByText("写真を採用できませんでした").waitFor();
  assert.equal(await body.inputValue(), beforeFailedAdoption);

  await page.getByLabel("タイトル", { exact: true }).fill("2026-09-20");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  const diaryDocument = await (await page.request.get(new URL("/api/authoring/drafts/" + legacyId, page.url()).href)).json();
  assert.equal(diaryDocument.metadata.page_type.value, "date");
  assert.equal(diaryDocument.metadata.page_date.value, "2026-09-20");
  await page.getByLabel("タイトル", { exact: true }).fill("日記ではない記事");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  const namedDocument = await (await page.request.get(new URL("/api/authoring/drafts/" + legacyId, page.url()).href)).json();
  assert.equal(namedDocument.metadata.page_type.value, "named");
  await page.setViewportSize({ width: 1600, height: 1000 });
  const previewMarkdown = `## 表とコード

| 時刻 | 事象 |
|---|---|
| 10:53 | 切り替え |

\`\`\`ruby
class User
end
\`\`\`

![カバー](/assets/photo.webp)

[[公開先]]`;
  await page.getByLabel("タイトル", { exact: true }).fill("作業版の表示確認");
  await body.fill(previewMarkdown);
  const preview = page.getByLabel("作業版の表示");
  await until(async () =>
    (await preview.locator(".article-reading-header h1").textContent()) ===
    "作業版の表示確認",
  );
  assert.equal(await preview.locator("table").count(), 1);
  assert.equal(
    await preview.locator("pre .hljs-keyword").first().textContent(),
    "class",
  );
  assert.ok(
    (await preview
      .locator(".article-reading-header img")
      .getAttribute("src"))?.endsWith("/assets/photo.webp"),
  );
  assert.equal(await page.locator("body > .site-header").count(), 0);
  assert.equal(await preview.getByRole("link", { name: "weblog.ason.as", exact: true }).count(), 1);
  assert.ok(await preview.locator(".line-update-rail__segment").count() > 0);
  assert.equal(await page.getByLabel("記事種別", { exact: true }).count(), 0);
  const firstPhoto = await photoColumn.getByRole("button", { name: "写真を本文へ追加" }).nth(0).boundingBox();
  const secondPhoto = await photoColumn.getByRole("button", { name: "写真を本文へ追加" }).nth(1).boundingBox();
  assert.ok(firstPhoto && secondPhoto && Math.abs(firstPhoto.y - secondPhoto.y) < 2, "two photos are visible in the first row");
  const dock = page.locator(".draft-editor__inbox");
  const beforeResize = await dock.boundingBox();
  const splitter = page.getByRole("separator", { name: "インボックスの高さ" });
  await splitter.focus();
  await splitter.press("ArrowUp");
  const afterKeyboardResize = await dock.boundingBox();
  assert.ok(afterKeyboardResize.height > beforeResize.height);
  const handle = await splitter.boundingBox();
  await page.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
  await page.mouse.down();
  await page.mouse.move(handle.x + handle.width / 2, handle.y - 30);
  await page.mouse.up();
  const afterDragResize = await dock.boundingBox();
  assert.ok(afterDragResize.height > afterKeyboardResize.height);
  assert.ok(Math.abs(afterDragResize.y + afterDragResize.height - page.viewportSize().height) < 2, "inbox reaches the viewport bottom");
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
  await page.screenshot({ path: "/tmp/weblog-draft-workspace-wide.png" });
  const wideSource = await page.locator(".draft-editor__source").boundingBox();
  const widthHandle = page.getByRole("separator", { name: "エディタの幅" });
  await widthHandle.focus();
  await page.keyboard.press("ArrowRight");
  assert.ok((await page.locator(".draft-editor__source").boundingBox()).width > wideSource.width);
  const handleBox = await widthHandle.boundingBox();
  await page.mouse.move(handleBox.x + 6, handleBox.y + 40);
  await page.mouse.down();
  await page.mouse.move(handleBox.x + 66, handleBox.y + 40);
  await page.mouse.up();
  assert.ok((await page.locator(".draft-editor__source").boundingBox()).width > wideSource.width + 40);
  const widePreview = await preview.boundingBox();
  assert.ok(wideSource && widePreview && widePreview.x >= wideSource.x + wideSource.width - 1);
  const popupPromise = page.waitForEvent("popup");
  await preview.getByRole("link", { name: "公開先" }).click();
  const publishedDestination = await popupPromise;
  assert.ok(decodeURI(publishedDestination.url()).endsWith("/公開先"));
  await publishedDestination.close();

  await page.setViewportSize({ width: 700, height: 900 });
  await setTimeout(250);
  assert.ok(
    await inbox.locator(".draft-inbox__columns").evaluate(
      (columns) => columns.scrollWidth > columns.clientWidth,
    ),
    "narrow layouts must retain horizontal access to every inbox column",
  );
  assert.equal(await preview.isVisible(), false);
  const pullBox = await page.getByRole("button", { name: "プレビュー" }).boundingBox();
  const workspaceBox = await page.locator(".draft-editor__workspace").boundingBox();
  assert.ok(Math.abs(pullBox.x + pullBox.width - workspaceBox.x - workspaceBox.width) < 2);
  assert.ok(Math.abs(pullBox.y + pullBox.height / 2 - workspaceBox.y - workspaceBox.height / 2) < 2);
  await page.getByRole("button", { name: "プレビュー" }).click();
  await setTimeout(250);
  assert.equal(await preview.isVisible(), true);
  await page.screenshot({ path: "/tmp/weblog-draft-workspace-narrow.png" });
  await page.getByRole("button", { name: "閉じる" }).click();
  await setTimeout(250);
  assert.equal(await preview.isVisible(), false);
  await page.context().setOffline(true);
  await page.evaluate(() => window.dispatchEvent(new Event("offline")));
  const beforeOfflineInsert = await body.inputValue();
  await inbox
    .getByRole("region", { name: "Bluesky" })
    .getByRole("button", { name: "Blueskyを本文へ追加" })
    .click();
  await inbox
    .getByText("オフラインでは素材を追加できません。本文の編集は続けられます。")
    .waitFor();
  assert.equal(await body.inputValue(), beforeOfflineInsert);
  await page.getByRole("button", { name: "プレビュー" }).click();
  await preview
    .getByText("オフラインのため画像や埋め込みを表示できません。本文の表示は更新されています。")
    .waitFor();
  await body.fill(`${previewMarkdown}\n\nオフラインで追記`);
  await until(async () =>
    (await preview.locator(".public-article-body").textContent()).includes(
      "オフラインで追記",
    ),
  );
  await page.context().setOffline(false);
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await page.setViewportSize({ width: 1280, height: 720 });

  await body.press("End");
  await body.pressSequentially("local undo");
  await body.press("Meta+z");
  assert.ok(!(await body.inputValue()).includes("local undo"));
  await body.press("Meta+Shift+z");
  assert.ok((await body.inputValue()).includes("local undo"));

  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let received = false;
  await page.route("**/uploads/*/commit", async (route) => {
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

  // API disconnection keeps the application shell available for an offline reload.
  await page.route("**/api/authoring/drafts/**", (route) => route.abort("internetdisconnected"));
  await body.fill("通信断の間に書いた本文");
  await until(async () => (await page.getByRole("status").textContent()).includes("端末に保存済み"));
  await page.reload();
  await until(async () => await body.inputValue() === "通信断の間に書いた本文");
  await page.unroute("**/api/authoring/drafts/**");
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));

  const sentIds = [];
  await page.route("**/uploads", async (route) => {
    sentIds.push(route.request().postDataJSON().update_id);
    await route.continue();
  });
  await page.route("**/uploads/*/commit", async (route) => {
    const response = await route.fetch();
    await route.abort("failed");
  }, { times: 1 });
  await body.fill("応答を失っても一度だけ保存する本文");
  await until(() => sentIds.length >= 2);
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  assert.equal(new Set(sentIds).size, 1);
  await page.unroute("**/uploads");
  await page.unroute("**/uploads/*/commit");

  let failedDuringDeploy = false;
  await page.route("**/uploads/*/commit", async (route) => {
    failedDuringDeploy = true;
    await route.fulfill({ status: 502, contentType: "text/html", body: "temporarily unavailable" });
  }, { times: 1 });
  await body.fill("デプロイ中のエラーから自動復旧した本文");
  await until(() => failedDuringDeploy);
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));

  let unauthorizedSends = 0;
  await page.route("**/uploads/*/commit", async (route) => {
    unauthorizedSends++;
    await route.fulfill({ status: 401, contentType: "application/json", body: JSON.stringify({ error: "ログインが必要です" }) });
  });
  await body.fill("ログイン切れでも保持する本文");
  await until(async () => (await page.locator(".draft-editor__status > [role=alert]").textContent()).includes("ログインが必要"));
  await setTimeout(2200);
  assert.equal(unauthorizedSends, 1);
  assert.equal(await body.inputValue(), "ログイン切れでも保持する本文");
  await page.unroute("**/uploads/*/commit");
  await page.getByRole("button", { name: "サーバー保存を再試行" }).click();
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));

  const remote = await browser.newContext();
  const remotePage = await remote.newPage();
  await remotePage.goto(url);
  await remotePage.getByRole("textbox", { name: "本文", exact: true }).fill("別端末からの追記");
  await until(async () => (await remotePage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.bringToFront();
  await until(async () => await body.inputValue() === "別端末からの追記");
  await body.evaluate((field) => {
    field.dispatchEvent(new CompositionEvent("compositionstart", { bubbles: true }));
    field.value += "ローカル変換";
  });
  await remotePage.getByRole("textbox", { name: "本文", exact: true }).fill("別端末からの追記リモート追記");
  await until(async () => (await remotePage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  await setTimeout(300);
  assert.equal(await body.inputValue(), "別端末からの追記ローカル変換");
  await body.evaluate((field) => field.dispatchEvent(new CompositionEvent("compositionend", { bubbles: true })));
  await until(async () => (await body.inputValue()).includes("リモート追記"));
  assert.ok((await body.inputValue()).includes("ローカル変換"));
  await body.press("Meta+z");
  assert.ok((await body.inputValue()).includes("リモート追記"));
  assert.ok(!(await body.inputValue()).includes("ローカル変換"));
  await remote.close();

  let savedDuringTyping = false;
  await page.route("**/uploads/*/commit", async (route) => {
    savedDuringTyping = true;
    await route.continue();
  }, { times: 1 });
  await body.focus();
  await body.press("ControlOrMeta+End");
  await body.pressSequentially("abcdefghijklmnopqrstuvwx", { delay: 250 });
  assert.ok(savedDuringTyping, "continuous input must start saving without waiting for idle");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));

  const competing = await browser.newContext();
  const competingPage = await competing.newPage();
  await competingPage.goto(url);
  await until(async () => (await competingPage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.route("**/api/authoring/drafts/**", (route) => route.abort("internetdisconnected"));
  await page.getByLabel("タイトル", { exact: true }).fill("端末側のタイトル");
  await body.fill("競合解決を待つ本文");
  await competingPage.getByLabel("タイトル", { exact: true }).fill("別端末側のタイトル");
  await until(async () => (await competingPage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.unroute("**/api/authoring/drafts/**");
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  const conflict = page.getByRole("group", { name: "タイトルの競合" });
  await conflict.waitFor();
  assert.ok((await conflict.textContent()).includes("別端末側のタイトル"));
  await page.reload();
  await conflict.waitFor();
  assert.equal(await page.getByLabel("タイトル", { exact: true }).inputValue(), "端末側のタイトル");
  assert.equal(await body.inputValue(), "競合解決を待つ本文");
  await conflict.getByRole("button", { name: "この端末の値を使う" }).focus();
  await page.keyboard.press("Enter");
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await competingPage.reload();
  await until(async () => await competingPage.getByLabel("タイトル", { exact: true }).inputValue() === "端末側のタイトル");

  let releaseConflict;
  const holdConflict = new Promise((resolve) => { releaseConflict = resolve; });
  let flightStarted = false;
  await page.route("**/uploads/*/commit", async (route) => {
    flightStarted = true;
    await holdConflict;
    await route.continue();
  }, { times: 1 });
  await page.getByLabel("タイトル", { exact: true }).fill("送信中に競合するタイトル");
  await until(() => flightStarted);
  await competingPage.getByLabel("タイトル", { exact: true }).fill("先に保存されたタイトル");
  await until(async () => (await competingPage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  releaseConflict();
  await conflict.waitFor();
  await conflict.getByRole("button", { name: "サーバーの値を使う" }).click();
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  assert.equal(await page.getByLabel("タイトル", { exact: true }).inputValue(), "先に保存されたタイトル");

  await page.route("**/api/authoring/drafts/**", (route) => route.abort("internetdisconnected"));
  await page.getByLabel("タイトル", { exact: true }).fill("別項目の変更とは競合しないタイトル");
  await competingPage.getByRole("button", { name: "カバー：自動", exact: true }).click();
  await competingPage.getByRole("radio", { name: "なし", exact: false }).check();
  await competingPage.getByRole("button", { name: "カバー設定を閉じる" }).click();
  await until(async () => (await competingPage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.unroute("**/api/authoring/drafts/**");
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  assert.equal(await conflict.count(), 0);
  assert.equal(await page.getByRole("button", { name: "カバー：なし", exact: true }).count(), 1);
  await competingPage.reload();
  await until(async () => await competingPage.getByLabel("タイトル", { exact: true }).inputValue() === "別項目の変更とは競合しないタイトル");
  await competing.close();

  const tabs = await browser.newContext();
  tabs.on("page", (tab) => tab.on("pageerror", (error) => errors.push(error.message)));
  await tabs.route("**/api/authoring/drafts/**", (route) => route.abort("internetdisconnected"));
  const tabA = await tabs.newPage();
  await tabA.goto("http://127.0.0.1:15182/draft-editor");
  const tabABody = tabA.getByRole("textbox", { name: "本文", exact: true });
  await tabABody.fill("共通の本文\n");
  await until(async () => (await tabA.getByRole("status").textContent()).includes("端末に保存済み"));
  const tabsUrl = tabA.url();
  const tabB = await tabs.newPage();
  await tabB.goto(tabsUrl);
  const tabBBody = tabB.getByRole("textbox", { name: "本文", exact: true });
  await until(async () => await tabBBody.inputValue() === "共通の本文\n");
  await Promise.all([
    tabABody.evaluate((field) => { field.value += "Aの追記\n"; field.dispatchEvent(new Event("input", { bubbles: true })); }),
    tabBBody.evaluate((field) => { field.value += "Bの追記\n"; field.dispatchEvent(new Event("input", { bubbles: true })); }),
  ]);
  await until(async () => (await tabABody.inputValue()).includes("Bの追記") && (await tabBBody.inputValue()).includes("Aの追記"));
  assert.equal(await tabABody.inputValue(), await tabBBody.inputValue());
  const mergedBody = await tabABody.inputValue();
  await tabABody.press("Meta+z");
  assert.ok((await tabABody.inputValue()).includes("Bの追記"));
  assert.ok(!(await tabABody.inputValue()).includes("Aの追記"));
  await tabABody.press("Meta+Shift+z");
  await until(async () => await tabBBody.inputValue() === mergedBody);
  await Promise.all([tabA.reload(), tabB.reload()]);
  await until(async () => await tabABody.inputValue() === mergedBody && await tabBBody.inputValue() === mergedBody);
  await Promise.all([
    tabA.getByLabel("タイトル", { exact: true }).fill("タブAのタイトル"),
    tabB.getByLabel("タイトル", { exact: true }).fill("タブBのタイトル"),
  ]);
  const tabConflict = tabA.getByRole("group", { name: "タイトルの競合" });
  await tabConflict.waitFor();
  assert.ok((await tabConflict.textContent()).includes("タブAのタイトル"));
  assert.ok((await tabConflict.textContent()).includes("タブBのタイトル"));
  await tabA.reload();
  await tabConflict.waitFor();
  await tabConflict.getByRole("button", { name: "この端末の値を使う" }).click();
  await until(async () => await tabB.getByRole("group", { name: "タイトルの競合" }).count() === 0);
  await tabB.close();
  const handoffIds = [];
  let responseLost = false;
  await tabs.route("**/uploads", async (route) => {
    handoffIds.push(route.request().postDataJSON().update_id);
    await route.continue();
  });
  await tabs.route("**/uploads/*/commit", async (route) => {
    const response = await route.fetch();
    if (!responseLost) {
      responseLost = true;
      await route.abort("failed");
    } else await route.fulfill({ response });
  });
  await tabs.unroute("**/api/authoring/drafts/**");
  await tabA.evaluate(() => window.dispatchEvent(new Event("online")));
  await until(() => responseLost);
  await tabA.close();
  const handoffTab = await tabs.newPage();
  await handoffTab.goto(tabsUrl);
  await until(async () => (await handoffTab.getByRole("status").textContent()).includes("サーバーに保存済み"));
  assert.ok(handoffIds.length >= 2);
  assert.equal(handoffIds[0], handoffIds[1]);
  await tabs.close();
  const recoveredTabs = await browser.newContext();
  const recoveredTab = await recoveredTabs.newPage();
  await recoveredTab.goto(tabsUrl);
  await until(async () => await recoveredTab.getByRole("textbox", { name: "本文", exact: true }).inputValue() === mergedBody);
  await recoveredTabs.close();

  const storageContext = await browser.newContext({ acceptDownloads: true });
  const storagePage = await storageContext.newPage();
  await storagePage.goto("http://127.0.0.1:15182/draft-editor");
  const storageBody = storagePage.getByRole("textbox", { name: "本文", exact: true });
  await storageBody.waitFor();
  await until(async () => await storageBody.isEnabled());
  await storageBody.fill("容量不足になる前の本文");
  await until(async () => (await storagePage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await storagePage.evaluate(() => {
    const original = IDBObjectStore.prototype.put;
    globalThis.restoreDraftStorage = () => { IDBObjectStore.prototype.put = original; };
    IDBObjectStore.prototype.put = function () { throw new DOMException("Storage quota exceeded", "QuotaExceededError"); };
  });
  let storageSends = 0;
  storagePage.on("request", (request) => {
    if (
      request.url().includes("/uploads/") &&
      request.url().endsWith("/commit")
    )
      storageSends++;
  });
  const retainedText = "# 保存容量不足でも失わない本文\n\n日本語と `code` を退避する。\n";
  await storageBody.fill(retainedText);
  await until(async () => (await storagePage.getByRole("status").textContent()).includes("端末に保存できません"));
  assert.equal(await storageBody.inputValue(), retainedText);
  const downloadPromise = storagePage.waitForEvent("download");
  await storagePage.getByRole("button", { name: "本文をダウンロード" }).click();
  const stream = await (await downloadPromise).createReadStream();
  const chunks = [];
  for await (const chunk of stream) chunks.push(chunk);
  assert.equal(Buffer.concat(chunks).toString("utf8"), retainedText);
  assert.equal(storageSends, 0);
  await storagePage.evaluate(() => globalThis.restoreDraftStorage());
  await storagePage.getByRole("button", { name: "サーバー保存を再試行" }).click();
  await until(async () => (await storagePage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await storagePage.reload();
  await until(async () => await storageBody.inputValue() === retainedText);
  const storageUrl = storagePage.url();
  await storageContext.close();
  const storageRecoveredContext = await browser.newContext();
  const storageRecoveredPage = await storageRecoveredContext.newPage();
  await storageRecoveredPage.goto(storageUrl);
  await until(async () => await storageRecoveredPage.getByRole("textbox", { name: "本文", exact: true }).inputValue() === retainedText);
  await storageRecoveredContext.close();

  const recoveryContext = await browser.newContext();
  const recoveryPage = await recoveryContext.newPage();
  await recoveryPage.goto("http://127.0.0.1:15182/draft-editor");
  const recoveryBody = recoveryPage.getByRole("textbox", {
    name: "本文",
    exact: true,
  });
  await recoveryBody.fill("復旧前に保存された本文");
  await until(async () =>
    (await recoveryPage.getByRole("status").textContent()).includes(
      "サーバーに保存済み",
    ),
  );
  const previousGenerationUrl = recoveryPage.url();
  await recoveryPage.route("**/api/authoring/drafts/**", (route) =>
    route.abort("internetdisconnected"),
  );
  await recoveryBody.fill("破損を避けて新しい下書きへ復旧する本文");
  await until(async () =>
    (await recoveryPage.locator(".draft-editor__status > [role=alert]").textContent()).includes("通信できません"),
  );
  await recoveryPage
    .getByRole("button", { name: "内容を新しい下書きへ復旧" })
    .click();
  await until(async () =>
    (await recoveryBody.inputValue()) ===
    "破損を避けて新しい下書きへ復旧する本文",
  );
  assert.notEqual(recoveryPage.url(), previousGenerationUrl);
  assert.ok(!new URL(recoveryPage.url()).searchParams.has("recovery"));
  await recoveryPage.unroute("**/api/authoring/drafts/**");
  await recoveryPage.evaluate(() => window.dispatchEvent(new Event("online")));
  await until(async () =>
    (await recoveryPage.getByRole("status").textContent()).includes(
      "サーバーに保存済み",
    ),
  );
  const recoveredGenerationUrl = recoveryPage.url();
  const generationCheck = await browser.newContext();
  const oldGeneration = await generationCheck.newPage();
  await oldGeneration.goto(previousGenerationUrl);
  await until(async () =>
    (await oldGeneration.getByRole("textbox", { name: "本文", exact: true }).inputValue()) ===
    "復旧前に保存された本文",
  );
  const newGeneration = await generationCheck.newPage();
  await newGeneration.goto(recoveredGenerationUrl);
  await until(async () =>
    (await newGeneration.getByRole("textbox", { name: "本文", exact: true }).inputValue()) ===
    "破損を避けて新しい下書きへ復旧する本文",
  );
  await generationCheck.close();
  await recoveryContext.close();

  await body.fill("あ".repeat(174_763));
  await until(async () => (await page.locator(".draft-editor__status > [role=alert]").textContent()).includes("512 KiB"));
  assert.equal((await body.inputValue()).length, 174_763);
  await page.reload();
  await until(async () => (await body.inputValue()).length === 174_763);
  const publicPages = await (await fetch("http://127.0.0.1:18082/api/pages")).json();
  assert.deepEqual(publicPages.pages, []);
  const publicationPage = await browser.newPage();
  await publicationPage.goto("http://127.0.0.1:15182/draft-editor");
  await publicationPage.getByLabel("タイトル", { exact: true }).fill("確認して公開する記事");
  const publicationBody = publicationPage.getByRole("textbox", { name: "本文", exact: true });
  await publicationBody.fill("# 公開する本文\n\n読者向けの内容");
  const publicationId = new URL(publicationPage.url()).searchParams.get("id");
  const readerUrl = `http://127.0.0.1:18082/api/pages/${publicationId}`;
  assert.equal((await fetch(readerUrl)).status, 404);
  let lostPublicationResponse = false;
  await publicationPage.route("**/publications", async (route) => {
    if (!lostPublicationResponse) {
      lostPublicationResponse = true;
      await route.fetch();
      await route.abort("failed");
    } else await route.continue();
  });
  await publicationPage.getByRole("button", { name: "公開", exact: true }).click();
  assert.equal(await publicationPage.getByRole("region", { name: "公開内容の確認" }).count(), 0);
  await until(async () => (await publicationPage.locator(".draft-editor__status > [role=alert]").textContent()).includes("通信できません"));
  await publicationPage.reload();
  let dispatchPolls = 0;
  await publicationPage.route("**/publications/*/run", async (route) => {
    const response = await route.fetch();
    const result = await response.json();
    await route.fulfill({ response, json: { ...result, dispatch: { id: "browser-dispatch", status: "queued" } } });
  });
  await publicationPage.route("**/publications/*?dispatch_id=browser-dispatch", async (route) => {
    dispatchPolls++;
    const response = await route.fetch();
    const result = await response.json();
    await route.fulfill({ response, json: { ...result, dispatch: { id: "browser-dispatch", status: dispatchPolls < 2 ? "running" : "completed" } } });
  });
  await fetch("http://127.0.0.1:18082/api/draft-test-search-failure", { method: "POST", headers: { "X-Draft-Test-Token": token } });
  await publicationPage.getByRole("button", { name: "公開を再試行", exact: true }).click();
  await until(async () => (await publicationPage.getByRole("status").textContent()).includes("公開が完了しました"));
  assert.ok(dispatchPolls >= 2, "Publication waits for asynchronous worker completion");
  assert.ok((await (await fetch(readerUrl)).text()).includes("読者向けの内容"));
  assert.ok((await (await fetch("http://127.0.0.1:18082/feed.xml")).text()).includes(`urn:uuid:${publicationId}`));
  await publicationPage.unroute("**/publications/*/run");
  await publicationPage.unroute("**/publications/*?dispatch_id=browser-dispatch");
  await publicationPage.getByRole("button", { name: "公開後の更新を再試行", exact: true }).click();
  await until(async () => (await publicationPage.getByRole("status").textContent()).includes("公開後の更新が完了しました"));
  assert.equal((await fetch(`http://127.0.0.1:18082/api/search?q=${encodeURIComponent("読者")}`)).status, 200);
  await publicationBody.fill("まだ見せない追記");
  await until(async () => (await publicationPage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  assert.ok(!(await (await fetch(readerUrl)).text()).includes("まだ見せない追記"));
  assert.ok((await (await fetch(`http://127.0.0.1:18082/${encodeURIComponent("確認して公開する記事")}`)).text()).includes("読者向けの内容"));
  let requestStarted = false;
  let releasePublication;
  const publicationGate = new Promise(resolve => { releasePublication = resolve; });
  await publicationPage.route("**/publications", async route => {
    requestStarted = true;
    await publicationGate;
    await route.continue();
  });
  await publicationPage.getByRole("button", { name: "公開", exact: true }).click();
  await until(async () => requestStarted);
  assert.equal(await publicationBody.isDisabled(), true);
  const concurrentContext = await browser.newContext();
  const concurrentPage = await concurrentContext.newPage();
  await concurrentPage.goto(publicationPage.url());
  const concurrentBody = concurrentPage.getByRole("textbox", { name: "本文", exact: true });
  await until(async () => (await concurrentBody.inputValue()) === "まだ見せない追記");
  await concurrentBody.fill("別のタブで追記した内容");
  await until(async () => (await concurrentPage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  releasePublication();
  await until(async () => (await publicationPage.locator(".draft-editor__status > [role=alert]").textContent()).includes("再確認してください"));
  assert.ok(!(await (await fetch(readerUrl)).text()).includes("別のタブで追記した内容"));
  await publicationPage.unroute("**/publications");
  await publicationPage.getByRole("button", { name: "公開", exact: true }).click();
  await until(async () => (await publicationPage.locator(".draft-editor__status > [role=alert]").textContent()).includes("合流しました"));
  await publicationPage.getByRole("button", { name: "公開", exact: true }).click();
  await until(async () => (await publicationPage.getByRole("status").textContent()).includes("公開が完了しました"));
  assert.ok((await (await fetch(readerUrl)).text()).includes("別のタブで追記した内容"));
  await concurrentContext.close();
  const referencePage = await browser.newPage();
  await referencePage.goto("http://127.0.0.1:15182/draft-editor");
  await referencePage.getByLabel("タイトル", { exact: true }).fill("名前変更の参照元");
  const referenceBody = referencePage.getByRole("textbox", { name: "本文", exact: true });
  await referenceBody.fill("公開リンク [[確認して公開する記事]]");
  await referencePage.getByRole("button", { name: "公開", exact: true }).click();
  await until(async () => (await referencePage.getByRole("status").textContent()).includes("公開が完了しました"));
  const referenceId = new URL(referencePage.url()).searchParams.get("id");
  await referenceBody.fill("非公開で編集中の参照元");
  await until(async () => (await referencePage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await publicationPage.getByLabel("タイトル", { exact: true }).fill("名前変更した記事");
  await publicationPage.getByRole("button", { name: "公開", exact: true }).click();
  await until(async () => (await publicationPage.getByRole("status").textContent()).includes("公開が完了しました"));
  const oldRouteUrl = `http://127.0.0.1:18082/${encodeURIComponent("確認して公開する記事")}`;
  await until(async () => (await fetch(oldRouteUrl, { redirect: "manual" })).status === 301);
  const oldRoute = await fetch(oldRouteUrl, { redirect: "manual" });
  assert.equal(oldRoute.status, 301);
  assert.ok(decodeURIComponent(oldRoute.headers.get("location")).endsWith("/名前変更した記事"));
  const publicReference = await (await fetch(`http://127.0.0.1:18082/api/pages/${referenceId}`)).text();
  assert.ok(publicReference.includes("名前変更した記事"));
  assert.ok(!publicReference.includes("非公開で編集中"));
  assert.equal(await referenceBody.inputValue(), "非公開で編集中の参照元");
  await referencePage.close();
  await publicationPage.close();
  assert.deepEqual(errors, []);
  console.log("PASS: reopen, shared public preview wide/narrow/offline, Undo/Redo, API-offline reload/reconnect, lost response retry, deployment failure recovery, remote refresh, continuous-input save, metadata conflicts/reload/choice/send race, independent metadata merge, same-browser offline tabs/reload/conflict/flight handoff, storage quota warning/export/recovery, explicit generation recovery, oversized retention, public isolation");
} finally {
  await browser?.close();
  for (const child of children) child.kill("SIGTERM");
}
