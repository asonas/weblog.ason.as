#!/usr/bin/env node
// 読み取り専用。記録した検証インスタンスが操作してよい状態かを確認する。
import { alive, apiBase, apiPort, health, listenerPid, processCwd, readState, root, webBase, webPort } from "./instance.mjs";

const state = readState();
let ok = true;
function report(pass, message) {
  console.log(`${pass ? "OK" : "NG"}: ${message}`);
  if (!pass) ok = false;
}

if (!state) {
  report(false, "検証インスタンスの記録がありません。launch.mjs で起動してください。");
  process.exit(1);
}
report(state.root === root, `記録したworktree ${state.root} と現在のworktree ${root}`);
for (const [name, info] of [["api", state.api], ["web", state.web]]) report(alive(info.pid), `${name} の起動プロセス PID ${info.pid}`);
for (const [name, port] of [["api", apiPort], ["web", webPort]]) {
  const pid = listenerPid(port);
  const cwd = pid && processCwd(pid);
  report(Boolean(pid) && cwd === root, `${name} ${port}番の待受 PID ${pid ?? "なし"}、cwd ${cwd ?? "不明"}`);
}
report((await health(apiBase)) === state.token, "API が自分のトークンを返す（別のfixtureサーバーではない）");
report((await health(webBase)) === state.token, "Vite が同じAPIへproxyしている");
const auth = await fetch(`${webBase}/api/auth/session`).then(r => (r.ok ? r.json() : null)).catch(() => null);
report(Boolean(auth?.can_edit), `編集権限 can_edit=${auth?.can_edit}`);
console.log(`pieces=${state.pieces} legacyDiary=${state.legacyDiary} startedAt=${state.startedAt}`);
process.exit(ok ? 0 : 1);
