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
  await until(async () => (await page.getByRole("alert").textContent()).includes("ログインが必要"));
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
  await competingPage.getByText("記事とカバーの設定", { exact: true }).click();
  await competingPage.getByLabel("記事種別", { exact: true }).selectOption("date");
  await until(async () => (await competingPage.getByRole("status").textContent()).includes("サーバーに保存済み"));
  await page.unroute("**/api/authoring/drafts/**");
  await page.evaluate(() => window.dispatchEvent(new Event("online")));
  await until(async () => (await page.getByRole("status").textContent()).includes("サーバーに保存済み"));
  assert.equal(await conflict.count(), 0);
  assert.equal(await page.getByLabel("記事種別", { exact: true }).inputValue(), "date");
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
    (await recoveryPage.getByRole("alert").textContent()).includes("通信できません"),
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
  await until(async () => (await page.getByRole("alert").textContent()).includes("512 KiB"));
  assert.equal((await body.inputValue()).length, 174_763);
  await page.reload();
  await until(async () => (await body.inputValue()).length === 174_763);
  const publicPages = await (await fetch("http://127.0.0.1:18082/api/pages")).json();
  assert.deepEqual(publicPages.pages, []);
  assert.deepEqual(errors, []);
  console.log("PASS: reopen, Undo/Redo, API-offline reload/reconnect, lost response retry, deployment failure recovery, remote refresh, continuous-input save, metadata conflicts/reload/choice/send race, independent metadata merge, same-browser offline tabs/reload/conflict/flight handoff, storage quota warning/export/recovery, explicit generation recovery, oversized retention, public isolation");
} finally {
  await browser?.close();
  for (const child of children) child.kill("SIGTERM");
}
