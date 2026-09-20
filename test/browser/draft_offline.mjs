import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, request } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const token = crypto.randomUUID();
const backend = spawn("mise", ["exec", "--", "ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], {
  env: { ...process.env, DRAFT_TEST_TOKEN: token }, stdio: ["ignore", "pipe", "pipe"],
});
let backendLog = "";
backend.stdout.on("data", (data) => { backendLog += data; });
backend.stderr.on("data", (data) => { backendLog += data; });
const root = resolve("dist/site");
let browser;
let server;
let slowAuthentication = false;
let rejectedWrites = 0;
const csrfToken = crypto.randomUUID();
try {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      if (await (await fetch("http://127.0.0.1:18082/api/draft-test-health")).text() === token) break;
    } catch {}
    await setTimeout(100);
    if (attempt === 99) throw new Error(`Fixture server did not start: ${backendLog}`);
  }
  server = createServer(async (req, res) => {
    if (req.url === "/api/auth/session") {
      if (slowAuthentication) await setTimeout(1500);
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ authenticated: true, authentication_required: true, can_edit: true, draft_authoring: true, login: "fixture", csrf_token: csrfToken }));
      return;
    }
    if (req.url.startsWith("/api/authoring/drafts/") && req.method !== "GET" && req.headers["x-csrf-token"] !== csrfToken) {
      rejectedWrites++;
      res.writeHead(403, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "CSRF token required" }));
      return;
    }
    if (req.url.startsWith("/api/")) {
      const upstream = request(`http://127.0.0.1:18082${req.url}`, {
        method: req.method, headers: { ...req.headers, host: "127.0.0.1:18082" },
      }, (response) => {
        res.writeHead(response.statusCode, response.headers);
        response.pipe(res);
      });
      upstream.on("error", () => { res.writeHead(502); res.end(); });
      req.pipe(upstream);
      return;
    }
    const pathname = new URL(req.url, "http://localhost").pathname;
    const path = pathname === "/draft-editor" ? "/index.html" : pathname;
    try {
      const file = resolve(root, `.${path}`);
      if (!file.startsWith(`${root}/`)) throw new Error("Invalid path");
      const body = await readFile(file);
      const type = path.endsWith(".js") ? "text/javascript" : path.endsWith(".css") ? "text/css" : "text/html";
      res.writeHead(200, { "Content-Type": type, "Cache-Control": "no-store" });
      res.end(body);
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise((resolve) => server.listen(15183, "127.0.0.1", resolve));
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("http://127.0.0.1:15183/draft-editor");
  const body = page.getByRole("textbox", { name: "本文", exact: true });
  await body.fill("オンラインで保存した本文");
  await page.getByRole("status").filter({ hasText: "サーバーに保存済み" }).waitFor();
  await page.getByText("オフラインでも再開できます", { exact: true }).waitFor({ timeout: 10000 });
  await context.setOffline(true);
  await body.fill("通信断の間に書いた本文");
  await page.getByRole("status").filter({ hasText: "端末に保存済み" }).waitFor();
  await page.reload();
  await body.waitFor();
  await page.waitForFunction(() => !document.querySelector('textarea[aria-label="本文"]')?.disabled);
  assert.equal(await body.inputValue(), "通信断の間に書いた本文");
  await body.fill("オフライン再開後の追記も保持");
  await page.getByRole("status").filter({ hasText: "端末に保存済み" }).waitFor();
  const savedUrl = page.url();
  await page.close();
  const reopened = await context.newPage();
  await reopened.goto(savedUrl);
  await reopened.waitForFunction(() => {
    const field = document.querySelector('textarea[aria-label="本文"]');
    return field && !field.disabled;
  });
  assert.equal(await reopened.getByRole("textbox", { name: "本文", exact: true }).inputValue(), "オフライン再開後の追記も保持");
  const cached = await reopened.evaluate(async () => {
    const urls = [];
    for (const name of await caches.keys()) {
      for (const entry of await (await caches.open(name)).keys()) urls.push(entry.url);
    }
    return urls;
  });
  assert.ok(cached.length > 0);
  assert.ok(cached.every((url) => !url.includes("/api/") && !url.includes("/assets/uploads/")));
  slowAuthentication = true;
  await context.setOffline(false);
  await reopened.getByRole("status").filter({ hasText: "サーバーに保存済み" }).waitFor();
  const fresh = await browser.newContext();
  const remote = await fresh.newPage();
  await remote.goto(savedUrl);
  await remote.getByRole("textbox", { name: "本文", exact: true }).waitFor();
  await remote.waitForFunction(() => !document.querySelector('textarea[aria-label="本文"]')?.disabled);
  assert.equal(await remote.getByRole("textbox", { name: "本文", exact: true }).inputValue(), "オフライン再開後の追記も保持");
  assert.equal(rejectedWrites, 0, "reconnect must wait for the fresh CSRF token");
  console.log("PASS: full offline reload, closed-tab reopen, local edit retention, reconnect, shell-only cache");
} finally {
  await browser?.close();
  await new Promise((resolve) => server ? server.close(resolve) : resolve());
  backend.kill("SIGTERM");
}
