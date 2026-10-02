import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const children = [];
const token = crypto.randomUUID();
const origin = "http://127.0.0.1:15182";

function start(args, env = {}) {
  const child = spawn("mise", ["exec", "--", ...args], {
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
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

async function openPage(context, url) {
  const page = await context.newPage();
  await page.route("**/assets/cover-*.webp", (route) => route.fulfill({
    path: "test/fixtures/article_comparison/assets/rubykaigi-follow-up.webp",
    contentType: "image/webp",
  }));
  await page.route("**/api/inbox", (route) => route.fulfill({
    contentType: "application/json", body: '{"items":[]}',
  }));
  await page.route("**/api/page-names", (route) => route.fulfill({
    contentType: "application/json", body: '{"names":[]}',
  }));
  await page.goto(url);
  return page;
}

let browser;
try {
  const apiLog = start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], {
    DRAFT_TEST_TOKEN: token,
  });
  const viteLog = start(["npm", "run", "dev", "--", "--port", "15182", "--strictPort"], {
    AUTHORING_API_ORIGIN: "http://127.0.0.1:18082",
  });
  await ready("http://127.0.0.1:18082/api/draft-test-health", apiLog);
  await ready(`${origin}/api/draft-test-health`, viteLog);
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext();
  const page = await openPage(context, `${origin}/draft-editor`);
  const body = page.getByRole("textbox", { name: "本文", exact: true });
  const source = "![花](/assets/cover-flower.webp)\n\n![海](/assets/cover-sea.webp)";
  await body.fill(source);
  await page.getByRole("button", { name: "記事の設定", exact: true }).click();
  const dialog = page.getByRole("dialog", { name: "記事の設定", exact: true });
  assert.ok(await dialog.getByRole("button", { name: "未公開の下書きを削除", exact: true }).isVisible());
  page.once("dialog", async confirmation => confirmation.dismiss());
  await dialog.getByRole("button", { name: "未公開の下書きを削除", exact: true }).click();
  assert.equal(await body.inputValue(), source);
  await dialog.getByRole("radio", { name: "画像を指定 本文の画像から選ぶ" }).check();
  const flower = dialog.getByRole("radio", { name: "画像1：花", exact: true });
  const sea = dialog.getByRole("radio", { name: "画像2：海", exact: true });
  assert.equal(await flower.isChecked(), true);
  for (const [alt, src] of [["花", "/assets/cover-flower.webp"], ["海", "/assets/cover-sea.webp"]]) {
    const image = dialog.getByRole("img", { name: alt, exact: true });
    assert.equal(await image.getAttribute("src"), src);
    await until(() => image.evaluate((element) => element.complete && element.naturalWidth > 0), `${alt} thumbnail did not load`);
  }
  await sea.check();
  assert.equal(await sea.isChecked(), true);
  assert.equal(await flower.isChecked(), false);
  assert.equal(await dialog.getByRole("img", { name: "選択中のカバー" }).getAttribute("src"), "/assets/cover-sea.webp");
  const previewCover = page.locator(".draft-preview__document .article-reading-header > img");
  await until(async () => await previewCover.getAttribute("src") === "/assets/cover-sea.webp", "Selected image was not reflected in article preview");
  for (const width of [390, 320]) {
    await page.setViewportSize({ width, height: 800 });
    const bounds = await dialog.boundingBox();
    assert.ok(bounds && bounds.x >= 0 && bounds.x + bounds.width <= width);
    assert.ok(await dialog.evaluate((element) => element.scrollWidth <= element.clientWidth));
  }
  await page.keyboard.press("Escape");
  await until(async () => (await page.locator(".draft-editor__sync-status").textContent()).includes("サーバーに保存済み"), "Cover selection was not saved");
  const url = page.url();
  const reopenedContext = await browser.newContext();
  const reopened = await openPage(reopenedContext, url);
  await until(async () => await reopened.getByRole("textbox", { name: "本文", exact: true }).inputValue() === source, "Body was not restored from server");
  await reopened.getByRole("button", { name: "記事の設定", exact: true }).click();
  const restoredDialog = reopened.getByRole("dialog", { name: "記事の設定", exact: true });
  assert.ok(await restoredDialog.getByRole("radio", { name: "画像2：海", exact: true }).isChecked());
  const restoredCover = reopened.locator(".draft-preview__document .article-reading-header > img");
  assert.equal(await restoredCover.getAttribute("src"), "/assets/cover-sea.webp");
  await restoredDialog.getByRole("radio", { name: "なし タイトルのみ" }).check();
  await until(async () => await restoredCover.count() === 0, "None mode still displays a cover");
  await restoredDialog.getByRole("radio", { name: "自動 本文の最初の画像" }).check();
  await until(async () => await restoredCover.getAttribute("src") === "/assets/cover-flower.webp", "Auto mode did not use the first image");
  console.log("PASS: visible body thumbnails, selection, public preview, 390/320px layout, server persistence in a fresh browser context, none/auto");
} finally {
  await browser?.close();
  for (const child of children) child.kill("SIGTERM");
}
