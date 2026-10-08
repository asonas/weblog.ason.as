import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const children = [];
const token = crypto.randomUUID();

function start(args, env = {}) {
  const child = spawn("mise", ["exec", "--", ...args], {
    env: { ...process.env, ...env },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (data) => {
    output += data;
  });
  child.stderr.on("data", (data) => {
    output += data;
  });
  children.push(child);
  return () => output;
}

async function ready(url, log) {
  for (let index = 0; index < 100; index++) {
    try {
      if ((await (await fetch(url)).text()) === token) return;
    } catch {}
    await setTimeout(100);
  }
  throw new Error(`Server did not start: ${log()}`);
}

async function until(check) {
  for (let index = 0; index < 300; index++) {
    if (await check()) return;
    await setTimeout(100);
  }
  assert.fail("Timed out waiting for video upload");
}

let browser;
try {
  const apiLog = start(
    ["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"],
    { DRAFT_TEST_TOKEN: token },
  );
  const viteLog = start(["npm", "run", "dev", "--", "--port", "15182"], {
    AUTHORING_API_ORIGIN: "http://127.0.0.1:18082",
  });
  await ready("http://127.0.0.1:18082/api/draft-test-health", apiLog);
  await ready("http://127.0.0.1:15182/api/draft-test-health", viteLog);

  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage();
  let registered;
  await page.route("**/api/inbox", (route) =>
    route.fulfill({ contentType: "application/json", body: JSON.stringify({ items: registered ? [{ id: "uploaded-video", source: "video", kind: "video", payload: registered }] : [] }) }),
  );
  await page.route("**/api/page-names", (route) =>
    route.fulfill({ contentType: "application/json", body: '{"names":[]}' }),
  );
  let uploads = 0;
  let shouldFail = false;
  const paths = [];
  let sent = 0;
  await page.route("**/api/uploads", (route) => {
    const payload = route.request().postDataJSON();
    if (payload.action === "register_video") {
      registered = payload;
      return route.fulfill({ contentType: "application/json", body: '{"item":{}}' });
    }
    assert.equal(payload.content_type, "video/mp4");
    assert.ok(payload.size > 0);
    uploads++;
    const path = `/assets/uploads/2026/10/${crypto.randomUUID()}.mp4`;
    paths.push(path);
    return route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        upload_url: "http://127.0.0.1:15182/test-video-upload",
        fields: { key: path.slice(1) },
        public_url: path,
      }),
    });
  });
  await page.route("**/test-video-upload", (route) => {
    sent++;
    assert.ok(route.request().postDataBuffer().includes(Buffer.from("ftyp")));
    return route.fulfill({ status: shouldFail ? 500 : 204 });
  });

  const id = crypto.randomUUID();
  const created = await page.request.put(
    `http://127.0.0.1:15182/api/authoring/drafts/${id}`,
    { data: { protocol: 1, generation: 1 } },
  );
  assert.equal(created.status(), 200);
  await page.goto(`http://127.0.0.1:15182/draft-editor?id=${id}`);
  const body = page.getByRole("textbox", { name: "本文", exact: true });
  const original = "動画の前\n\n動画の後";
  await body.fill(original);
  await page.evaluate(async () => {
    const canvas = document.createElement("canvas");
    canvas.width = 64;
    canvas.height = 64;
    const stream = canvas.captureStream(30);
    const recorder = new MediaRecorder(stream, { mimeType: "video/webm;codecs=vp8" });
    const parts = [];
    recorder.ondataavailable = (event) => parts.push(event.data);
    const stopped = new Promise((resolve) => { recorder.onstop = resolve; });
    recorder.start();
    const context = canvas.getContext("2d");
    for (let index = 0; index < 12; index++) {
      context.fillStyle = index % 2 ? "red" : "blue";
      context.fillRect(0, 0, 64, 64);
      await new Promise((resolve) => setTimeout(resolve, 40));
    }
    recorder.stop();
    await stopped;
    stream.getTracks().forEach((track) => track.stop());
    window.testVideo = new Blob(parts, { type: "video/webm" });
  });
  await body.evaluate(async (field) => {
    field.setSelectionRange(5, 5);
    const file = new File([window.testVideo], "clip[1].webm", {
      type: "video/webm",
    });
    const transfer = new DataTransfer();
    transfer.items.add(file);
    field.dispatchEvent(
      new DragEvent("drop", {
        bubbles: true,
        cancelable: true,
        dataTransfer: transfer,
      }),
    );
  });

  await until(async () => {
    const error = (await page.locator('[role="alert"]').allTextContents()).filter(Boolean).join("\n");
    if (error) throw new Error(error);
    return !!registered;
  });
  await until(async () => (await body.inputValue()).includes(paths[0]));
  assert.equal(sent, uploads);
  assert.ok(uploads >= 1);
  assert.equal(registered.avc, paths[0]);
  assert.equal(registered.width, 64);
  assert.equal(registered.height, 64);
  assert.equal(
    await body.inputValue(),
    `動画の前\n\n[clip\\[1\\].webm](${registered.avc})\n\n動画の後`,
  );
  await until(async () => await page.locator('.draft-preview video[data-avc]').count() === 1);
  assert.equal(await page.locator('.draft-preview video[data-avc]').getAttribute('data-avc'), registered.avc);
  const successful = await body.inputValue();
  shouldFail = true;
  await body.evaluate(async (field) => {
    field.setSelectionRange(0, 0);
    const file = new File([window.testVideo], "pasted.webm", {
      type: "video/webm",
    });
    const transfer = new DataTransfer();
    transfer.items.add(file);
    field.dispatchEvent(
      new ClipboardEvent("paste", {
        bubbles: true,
        cancelable: true,
        clipboardData: transfer,
      }),
    );
  });

  await until(async () => ((await page.locator('[role="alert"]').allTextContents()).filter(Boolean).join("\n")).includes("動画をS3へ送信できませんでした"));
  assert.equal(await body.inputValue(), successful);
  assert.equal(await body.isEnabled(), true);
  const requestsBeforeCancel = uploads;
  await body.evaluate((field) => {
    const transfer = new DataTransfer();
    transfer.items.add(new File([window.testVideo], "cancel.webm", { type: "video/webm" }));
    field.dispatchEvent(new ClipboardEvent("paste", { bubbles: true, cancelable: true, clipboardData: transfer }));
  });
  await page.getByRole("button", { name: "動画の追加をキャンセル", exact: true }).click();
  await until(() => body.isEnabled());
  assert.equal(await body.inputValue(), successful);
  assert.equal(uploads, requestsBeforeCancel);
  await page.getByRole("region", { name: "動画", exact: true }).getByRole("button", { name: "動画を本文へ追加", exact: true }).click();
  await until(async () => (await body.inputValue()).length > successful.length);
  assert.equal(uploads, requestsBeforeCancel, "Material reuse must not upload again");
  assert.equal((await body.inputValue()).includes(":::video"), false);
  assert.equal((await body.inputValue()).split(`[clip\\[1\\].webm](${paths[0]})`).length, 3);
  assert.equal((await body.inputValue()).split(paths[0]).length, 3);
  await until(async () => await page.locator('.draft-preview video[data-avc]').count() === 2);
  console.log(
    "PASS: real conversion and Markdown insertion, failed paste, cancellation and material reuse",
  );
} finally {
  await browser?.close();
  for (const child of children) child.kill("SIGTERM");
}
