import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { setTimeout } from "node:timers/promises";
import { chromium } from "playwright-core";

const children = [];
const token = crypto.randomUUID();
const pieces = process.env.ARTICLE_PIECES_ENABLED !== "false";
function start(args, env = {}) {
  const child = spawn("mise", ["exec", "--", ...args], {
    env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.resume();
  child.stderr.resume();
  children.push(child);
}
let browser;
try {
  start(["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], {
    DRAFT_TEST_TOKEN: token, ARTICLE_PIECES_ENABLED: String(pieces),
  });
  start(["npm", "run", "dev", "--", "--port", "15182", "--strictPort"], {
    AUTHORING_API_ORIGIN: "http://127.0.0.1:18082",
  });
  let ready = false;
  for (let i = 0; i < 150; i++) {
    try { ready = await (await fetch("http://127.0.0.1:15182/api/draft-test-health")).text() === token; } catch {}
    if (ready) break;
    await setTimeout(100);
  }
  assert.ok(ready, "Isolated test server is ready");
  browser = await chromium.launch({ channel: "chrome", headless: true });
  const page = await browser.newPage({ viewport: { width: 1568, height: 1000 } });
  const errors = [];
  page.on("pageerror", error => errors.push(error.message));
  await page.goto("http://127.0.0.1:15182/draft-editor");
  await page.getByRole("textbox", { name: "タイトル", exact: true }).fill("2026-10-29");
  const body = page.getByRole("textbox", { name: pieces ? "1番目のかけら" : "本文", exact: true });
  const paragraphs = Array.from({ length: 40 }, (_, index) => `段落 ${index + 1}`);
  await body.fill(paragraphs.join("\n\n"));
  const preview = page.getByLabel("作業版の表示", { exact: true });
  const selectParagraph = async (index) => {
    await body.evaluate((field, text) => {
      const position = field.value.indexOf(text) + text.length;
      field.setSelectionRange(position, position);
      field.dispatchEvent(new Event("select", { bubbles: true }));
    }, paragraphs[index]);
    await body.press("ArrowLeft");
    await body.press("ArrowRight");
  };
  for (const height of [1000, 720]) {
    await page.setViewportSize({ width: 1568, height });
    for (const index of [19, 24]) {
      await selectParagraph(index);
      await setTimeout(100);
      console.log("selection", await preview.getByText(paragraphs[index], { exact: true }).evaluate(element => {
        const scroller = element.closest(".draft-preview");
        return { top: element.getBoundingClientRect().top - scroller.getBoundingClientRect().top, height: scroller.clientHeight };
      }));
      await page.waitForFunction(text => {
        const scroller = document.querySelector(".draft-preview");
        const target = [...scroller.querySelectorAll(".public-article-body p")].find(p => p.textContent === text);
        return target && Math.abs(target.getBoundingClientRect().top - scroller.getBoundingClientRect().top - scroller.clientHeight / 2) < 2;
      }, paragraphs[index], { timeout: 5000 });
      await body.pressSequentially("a");
      paragraphs[index] += "a";
      const geometry = await preview.getByText(paragraphs[index], { exact: true }).evaluate(element => {
        const scroller = element.closest(".draft-preview");
        return { top: element.getBoundingClientRect().top - scroller.getBoundingClientRect().top, height: scroller.clientHeight };
      });
      assert.ok(Math.abs(geometry.top - geometry.height / 2) < 2, JSON.stringify(geometry));
      console.log(JSON.stringify({ pieces, viewportHeight: height, ...geometry }));
    }
  }
  await preview.screenshot({ path: `/private/tmp/aso-13-preview-${pieces ? "pieces" : "legacy"}.png` });
  await selectParagraph(0);
  await page.waitForFunction(() => {
    const element = document.querySelector(".draft-preview");
    const target = element.querySelector(".public-article-body p");
    const offset = target.getBoundingClientRect().top - element.getBoundingClientRect().top;
    return Math.abs(offset - element.clientHeight / 2) < 2 || (element.scrollTop === 0 && offset < element.clientHeight / 2);
  });
  await selectParagraph(39);
  await page.waitForFunction(() => {
    const element = document.querySelector(".draft-preview");
    const target = [...element.querySelectorAll(".public-article-body p")].at(-1);
    const offset = target.getBoundingClientRect().top - element.getBoundingClientRect().top;
    return Math.abs(offset - element.clientHeight / 2) < 2 ||
      (Math.abs(element.scrollTop - (element.scrollHeight - element.clientHeight)) < 2 && offset > element.clientHeight / 2);
  });
  if (pieces) {
    await page.route("**/assets/preview-scroll.webp", route => route.fulfill({
      path: "test/fixtures/article_comparison/assets/rubykaigi-follow-up.webp",
      contentType: "image/webp",
    }));
    await page.getByRole("button", { name: "かけらを追加", exact: true }).click();
    const second = page.getByRole("textbox", { name: "2番目のかけら", exact: true });
    await second.fill(`![写真](/assets/preview-scroll.webp)\n\nあああ\n\n${paragraphs.join("\n\n")}`);
    await preview.locator(".public-article-body img").evaluate(image => image.decode());
    await second.evaluate(field => {
      const position = field.value.indexOf("あああ") + 3;
      field.setSelectionRange(position, position);
    });
    await second.press("ArrowLeft");
    await second.press("ArrowRight");
    await second.pressSequentially("a");
    await page.waitForFunction(() => {
      const scroller = document.querySelector(".draft-preview");
      const target = [...scroller.querySelectorAll(".article-image-text-group p")].find(p => p.textContent === "あああa");
      return target && Math.abs(target.getBoundingClientRect().top - scroller.getBoundingClientRect().top - scroller.clientHeight / 2) < 2;
    });
    console.log("image-following paragraph", await preview.getByText("あああa", { exact: true }).evaluate(element => {
      const scroller = element.closest(".draft-preview");
      return { top: element.getBoundingClientRect().top - scroller.getBoundingClientRect().top, height: scroller.clientHeight };
    }));
    await preview.screenshot({ path: "/private/tmp/aso-13-preview-image-pieces.png" });
  }
  assert.deepEqual(errors, []);
  console.log(`PASS: ${pieces ? "pieces" : "legacy"} preview centers selection and typing, preserves scroll boundaries`);
} finally {
  await browser?.close();
  for (const child of children.reverse()) child.kill("SIGTERM");
}
