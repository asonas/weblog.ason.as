import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";
import { PNG } from "pngjs";
import jsQR from "jsqr";

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
  for (let i = 0; i < 100; i++) { if (await check()) return; await setTimeout(100); }
  assert.fail("Timed out waiting for pairing state");
}
let browser;
try {
  const apiLog = start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], { DRAFT_TEST_TOKEN: token });
  const viteLog = start(["node", "node_modules/vite/bin/vite.js", "--port", "15182", "--strictPort"], { AUTHORING_API_ORIGIN: "http://127.0.0.1:18082" });
  await ready("http://127.0.0.1:18082/api/draft-test-health", apiLog);
  await ready("http://127.0.0.1:15182/api/draft-test-health", viteLog);
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto("http://127.0.0.1:15182/authoring/articles");
  await page.getByRole("link", { name: "端末を管理" }).click();
  await page.getByRole("heading", { name: "端末", exact: true }).waitFor();
  await page.getByText("まだペアリング済みの端末はありません。", { exact: true }).waitFor();
  const issue = page.getByRole("button", { name: "新たにペアリング", exact: true });
  const qr = page.getByRole("img", { name: "ペアリング用QRコード" });
  let issues = 0;
  page.on("request", request => { if (request.method() === "POST" && request.url().endsWith("/api/mobile/pairings")) issues++; });
  await issue.focus();
  await page.keyboard.press("Enter");
  await qr.waitFor();
  assert.equal(issues, 1);
  const png = PNG.sync.read(Buffer.from((await qr.getAttribute("src")).split(",")[1], "base64"));
  const decoded = jsQR(new Uint8ClampedArray(png.data), png.width, png.height);
  assert.ok(decoded, "The rendered QR image must decode");
  const payload = JSON.parse(decoded.data);
  assert.equal(payload.type, "weblog-photo-inbox-pairing");
  assert.equal(payload.version, 1);
  assert.equal(payload.server, "https://weblog.ason.as");
  assert.match(payload.code, /^[A-Z2-7]{12}$/);
  assert.ok(Date.parse(payload.expires_at) > Date.now());
  assert.equal(await page.locator(".mobile-pairing-code").textContent(), payload.code);
  for (const width of [1440, 320]) {
    await page.setViewportSize({ width, height: 1000 });
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
    const rendered = PNG.sync.read(await qr.screenshot());
    assert.equal(jsQR(new Uint8ClampedArray(rendered.data), rendered.width, rendered.height)?.data, decoded.data);
    await page.screenshot({ path: `/tmp/weblog-mobile-pairing-${width}.png`, fullPage: true });
  }
  const exchange = await page.request.post("http://127.0.0.1:15182/api/mobile/pairings/exchange", { data: { code: payload.code, device_name: "Android test device" } });
  assert.equal(exchange.status(), 201);
  await page.getByRole("heading", { name: "Android test device" }).waitFor();
  await until(async () => !(await qr.count()));
  assert.equal(await issue.evaluate(element => element === document.activeElement), true);
  assert.match(await page.getByRole("status").textContent(), /ペアリングしました/);
  assert.equal((await page.request.post("http://127.0.0.1:15182/api/mobile/pairings/exchange", { data: { code: payload.code, device_name: "Duplicate" } })).status(), 410);

  await page.route("**/api/mobile/pairings", route => route.fulfill({ status: 503 }));
  await issue.click();
  await page.getByRole("alert").waitFor();
  assert.equal(await qr.count(), 0);
  await page.unroute("**/api/mobile/pairings");
  await page.route("**/api/mobile/pairings", async route => {
    const response = await route.fetch();
    await route.fulfill({ response, json: { ...await response.json(), expires_at: new Date(Date.now() + 1500).toISOString() } });
  });
  await issue.click();
  await qr.waitFor();
  await until(async () => !(await qr.count()));
  assert.match(await page.getByRole("status").textContent(), /有効期限が切れました/);
  await page.unroute("**/api/mobile/pairings");

  await page.route("**/api/mobile/devices", route => route.fulfill({ status: 503 }));
  await page.getByRole("button", { name: "再読み込み" }).click();
  await page.getByRole("alert").waitFor();
  assert.equal(await page.getByRole("heading", { name: "Android test device" }).count(), 1);
  await page.unroute("**/api/mobile/devices");
  await page.getByRole("button", { name: "再読み込み" }).click();
  await until(async () => !(await page.getByRole("alert").count()));
  await page.reload();
  await page.getByRole("heading", { name: "Android test device" }).waitFor();
  assert.equal(await qr.count(), 0);
  await page.route("**/api/auth/session", route => route.fulfill({ json: { can_edit: false, authenticated: false, authentication_required: true, csrf_token: "" } }));
  await page.reload();
  await page.getByText("端末を管理するにはログインしてください。", { exact: true }).waitFor();
  assert.equal(await issue.count(), 0);
  assert.deepEqual(errors, []);
  console.log("PASS: QR decode, real pairing exchange, device list, expiry, retry, keyboard, narrow layout, authorization");
} finally {
  await browser?.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
