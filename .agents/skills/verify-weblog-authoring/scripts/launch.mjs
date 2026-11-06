#!/usr/bin/env node
// fixture API（一時ディレクトリのDB、AWSは stub）とViteを起動し、使える状態になるまで待って終了する。
// 起動したプロセスは残り、cleanup.mjs が停止する。
import { spawn } from "node:child_process";
import { mkdirSync, openSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { setTimeout } from "node:timers/promises";
import { apiBase, apiPort, health, listenerPid, readState, root, stateDir, statePath, webBase, webPort } from "./instance.mjs";

const legacyDiary = process.argv.includes("--legacy-diary");
const pieces = process.argv.includes("--pieces");

if (readState()) {
  console.error(`既存の検証インスタンスの記録があります: ${statePath}\n先に doctor.mjs で確認し、不要なら cleanup.mjs で停止してください。`);
  process.exit(1);
}
for (const port of [apiPort, webPort]) {
  const pid = listenerPid(port);
  if (pid) {
    console.error(`${port}番は PID ${pid} が使用中です。他のブラウザテストか別のworktreeの検証が動いている可能性があります。起動元を確認するまで止めないでください。`);
    process.exit(1);
  }
}

mkdirSync(stateDir, { recursive: true });
const token = crypto.randomUUID();
function start(name, args, env) {
  const log = resolve(stateDir, `${name}.log`);
  const fd = openSync(log, "w");
  const child = spawn("mise", ["exec", "--", ...args], {
    cwd: root,
    env: { ...process.env, ...env },
    stdio: ["ignore", fd, fd],
    detached: true,
  });
  child.unref();
  return { pid: child.pid, log };
}

const api = start("api", ["ruby", "-rbundler/setup", "test/fixtures/drafts/server.rb"], {
  DRAFT_TEST_TOKEN: token,
  ARTICLE_PIECES_ENABLED: pieces ? "true" : "false",
  ...(legacyDiary ? { DRAFT_TEST_LEGACY_DIARY: "1" } : {}),
});
const web = start("web", ["node", "node_modules/vite/bin/vite.js", "--port", String(webPort), "--strictPort"], {
  AUTHORING_API_ORIGIN: apiBase,
});
writeFileSync(statePath, JSON.stringify({ token, root, api, web, pieces, legacyDiary, startedAt: new Date().toISOString() }, null, 2));

for (let i = 0; i < 300; i++) {
  if ((await health(apiBase)) === token && (await health(webBase)) === token) {
    // health が返っても、画面が実際に描画できるまでは使える状態ではない。
    const page = await fetch(`${webBase}/authoring/articles`).catch(() => null);
    if (page?.ok) {
      console.log(`ready: ${webBase} (API ${apiBase})\nstate: ${statePath}`);
      process.exit(0);
    }
  }
  await setTimeout(100);
}
console.error(`30秒以内に起動しませんでした。ログ: ${api.log} ${web.log}\ncleanup.mjs で停止してください。`);
process.exit(1);
