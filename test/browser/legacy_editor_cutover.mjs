import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const server = spawn("mise", ["exec", "--", "node", "node_modules/vite/bin/vite.js", "--port", "15184"], { stdio: ["ignore", "pipe", "pipe"] });
let output = "";
server.stdout.on("data", data => { output += data; });
server.stderr.on("data", data => { output += data; });
let browser;
try {
  for (let attempt = 0; !output.includes("http://127.0.0.1:15184/"); attempt++) {
    if (attempt > 100 || server.exitCode !== null) throw new Error(output);
    await setTimeout(100);
  }
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage({ viewport: { width: 1000, height: 900 }, acceptDownloads: true });
  let writes = 0;
  let navigations = 0;
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  page.on("framenavigated", frame => { if (frame === page.mainFrame()) navigations++; });
  await page.route("**/api/**", async route => {
    const pathname = new URL(route.request().url()).pathname;
    let payload = { items: [], names: [], results: [] };
    let status = 200;
    if (pathname === "/api/auth/session") payload = { authenticated: true, authentication_required: false, can_edit: true, csrf_token: "test" };
    if (pathname === "/api/pages/page-id") payload = {
      mode: "editor", page_id: "page-id", page_type: "named", name: "current", title: "current", date: "", body: "本文", expected_updated_at: "2026-09-20T00:00:00Z", save_message: "", linked_pages: [], linked_pages_has_more: false,
    };
    if (pathname.startsWith("/api/authoring/pages")) { writes++; status = 409; payload = { code: "upgrade_required", error: "obsolete writer" }; }
    await route.fulfill({ status, contentType: "application/json", body: JSON.stringify(payload) });
  });
  await page.goto("http://127.0.0.1:15184/editor/page-id");
  const body = page.locator(".ProseMirror p").last();
  await body.click();
  await page.keyboard.press("End");
  await page.keyboard.insertText(" 未保存の追記");
  const protection = page.getByRole("region", { name: "未保存の内容を保護" });
  await protection.getByText("保存方式が切り替わりました。このタブからは保存できません。").waitFor();
  await body.click();
  await page.keyboard.press("End");
  await page.keyboard.insertText(" 通知後の追記");
  const downloadEvent = page.waitForEvent("download");
  await protection.getByRole("button", { name: "Markdownをダウンロード" }).click();
  const download = await downloadEvent;
  assert.equal(await readFile(await download.path(), "utf8"), "# current\n\n本文 未保存の追記 通知後の追記");
  assert.equal(download.suggestedFilename(), "current.md");
  await setTimeout(500);
  assert.equal(writes, 1);
  assert.equal(navigations, 1);
  assert.equal(await body.textContent(), "本文 未保存の追記 通知後の追記");
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  const narrowDownloadEvent = page.waitForEvent("download");
  await protection.getByRole("button", { name: "Markdownをダウンロード" }).click();
  assert.equal(await readFile(await (await narrowDownloadEvent).path(), "utf8"), "# current\n\n本文 未保存の追記 通知後の追記");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.screenshot({ path: "/tmp/weblog-171-protection.png", fullPage: true });
  assert.deepEqual(errors, []);
  console.log("PASS: rejected legacy save retains editable text, downloads current Markdown, stops writes and does not reload");
} finally {
  await browser?.close();
  server.kill("SIGTERM");
}
