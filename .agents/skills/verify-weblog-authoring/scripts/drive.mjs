#!/usr/bin/env node
// 使い方: node .agents/skills/verify-weblog-authoring/scripts/drive.mjs <journey.mjs> [label]
// journey.mjs は `export default async ({ page, context, webBase, evidence, shot, step }) => {}` を公開する。
// ブラウザを起動し、操作ログ・console・pageerror・スクリーンショットを証拠ディレクトリへ保存する。
import { appendFileSync, writeFileSync } from "node:fs";
import { basename, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { chromium } from "playwright-core";
import { health, newEvidenceDir, readState, webBase } from "./instance.mjs";

const [journeyPath, labelArg] = process.argv.slice(2);
if (!journeyPath) {
  console.error("usage: drive.mjs <journey.mjs> [label]");
  process.exit(2);
}
const state = readState();
if (!state || (await health(webBase)) !== state.token) {
  console.error("検証インスタンスが自分のものとして応答しません。doctor.mjs を実行してください。");
  process.exit(1);
}
const journey = (await import(pathToFileURL(resolve(journeyPath)).href)).default;
const evidence = newEvidenceDir(labelArg ?? basename(journeyPath, ".mjs"));
const logPath = resolve(evidence, "journey.log");
const log = line => appendFileSync(logPath, `${new Date().toISOString()} ${line}\n`);
const errors = [];

const browser = await chromium.launch({ channel: "chrome", headless: true });
let failed = null;
let page;
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 960 }, locale: "ja-JP" });
  page = await context.newPage();
  page.on("console", message => log(`console.${message.type()} ${message.text()}`));
  page.on("pageerror", error => { errors.push(error.message); log(`pageerror ${error.message}`); });
  page.on("requestfailed", request => log(`requestfailed ${request.method()} ${request.url()} ${request.failure()?.errorText}`));
  let shots = 0;
  const shot = async name => {
    const path = resolve(evidence, `${String(++shots).padStart(2, "0")}-${name}.png`);
    await page.screenshot({ path, fullPage: true });
    log(`screenshot ${path}`);
    return path;
  };
  const step = message => { log(`step ${message}`); console.log(`step: ${message}`); };
  await journey({ page, context, webBase, evidence, shot, step });
  await shot("final");
} catch (error) {
  failed = error;
  log(`failed ${error.stack ?? error}`);
  // 失敗時も、その瞬間の画面を証拠として残す。
  await page?.screenshot({ path: resolve(evidence, "failure.png"), fullPage: true }).catch(() => {});
} finally {
  await browser.close();
}
writeFileSync(resolve(evidence, "result.json"), JSON.stringify({ journey: resolve(journeyPath), passed: !failed && errors.length === 0, error: failed ? String(failed) : null, pageErrors: errors }, null, 2));
console.log(`evidence: ${evidence}`);
if (failed || errors.length) {
  console.error(failed ? `FAIL: ${failed.message}` : `FAIL: pageerror ${errors.join(" / ")}`);
  process.exit(1);
}
console.log("PASS");
