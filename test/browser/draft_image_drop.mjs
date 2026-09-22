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
  for (let index = 0; index < 100; index++) {
    if (await check()) return;
    await setTimeout(100);
  }
  assert.fail("Timed out waiting for dropped image Markdown");
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
  await page.route("**/api/inbox", (route) =>
    route.fulfill({ contentType: "application/json", body: '{"items":[]}' }),
  );
  await page.route("**/api/page-names", (route) =>
    route.fulfill({ contentType: "application/json", body: '{"names":[]}' }),
  );
  await page.route("**/assets/uploads/drop-source.webp", (route) =>
    route.fulfill({
      path: "test/fixtures/article_comparison/assets/rubykaigi-follow-up.webp",
      contentType: "image/webp",
    }),
  );
  let uploads = 0;
  await page.route("**/api/uploads", (route) => {
    uploads++;
    return route.fulfill({
      contentType: "application/json",
      body: JSON.stringify({
        upload_url: "http://127.0.0.1:15182/test-image-upload",
        fields: { key: "assets/uploads/2026/09/dropped-image.webp" },
        public_url: "/assets/uploads/2026/09/dropped-image.webp",
      }),
    });
  });
  await page.route("**/test-image-upload", (route) =>
    route.fulfill({ status: 204 }),
  );

  const id = crypto.randomUUID();
  const created = await page.request.put(
    `http://127.0.0.1:15182/api/authoring/drafts/${id}`,
    { data: { protocol: 1, generation: 1 } },
  );
  assert.equal(created.status(), 200);
  await page.goto(`http://127.0.0.1:15182/draft-editor?id=${id}`);
  const body = page.getByRole("textbox", { name: "本文", exact: true });
  await body.fill("画像の前\n\n画像の後");
  await body.evaluate(async (field) => {
    field.setSelectionRange(5, 5);
    const response = await fetch("/assets/uploads/drop-source.webp");
    const file = new File([await response.blob()], "drop-source.webp", {
      type: "image/webp",
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

  await until(() => uploads === 1);
  await until(async () =>
    (await body.inputValue()).includes("/assets/uploads/2026/09/dropped-image.webp"),
  );
  assert.equal(
    await body.inputValue(),
    "画像の前\n\n![](/assets/uploads/2026/09/dropped-image.webp)\n\n画像の後",
  );

  await body.evaluate(async (field) => {
    field.setSelectionRange(0, 0);
    const response = await fetch("/assets/uploads/drop-source.webp");
    const file = new File([await response.blob()], "pasted-source.webp", {
      type: "image/webp",
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

  await until(() => uploads === 2);
  await until(async () => (await body.inputValue()).startsWith("![]("));
  assert.equal(
    await body.inputValue(),
    "![](/assets/uploads/2026/09/dropped-image.webp)\n\n画像の前\n\n![](/assets/uploads/2026/09/dropped-image.webp)\n\n画像の後",
  );
  console.log(
    "PASS: dropped and pasted images upload and insert Markdown at the textarea selection",
  );
} finally {
  await browser?.close();
  for (const child of children) child.kill("SIGTERM");
}
