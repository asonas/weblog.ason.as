#!/usr/bin/env node
// launch.mjs が起動したプロセスグループだけを停止し、記録を消す。証拠ディレクトリは残す。
import { rmSync } from "node:fs";
import { setTimeout } from "node:timers/promises";
import { alive, apiPort, evidenceRoot, listenerPid, processCwd, readState, statePath, webPort } from "./instance.mjs";

const state = readState();
if (!state) {
  console.log("停止する検証インスタンスの記録はありません。");
  process.exit(0);
}
// 異常終了後にPIDが別のプロセスへ再利用されていることがあるため、cwdがこのworktreeのものだけを止める。
for (const info of [state.web, state.api]) {
  if (alive(info.pid) && processCwd(info.pid) !== state.root) {
    console.error(`PID ${info.pid} はこのworktreeで起動したプロセスではありません。止めずに記録だけ消します。`);
    info.pid = -1;
  }
}
for (const info of [state.web, state.api].filter(info => info.pid > 0)) {
  // detached で起動したので PID がプロセスグループIDになる。SIGTERMでpumaが一時DBを片付ける。
  try { process.kill(-info.pid, "SIGTERM"); } catch {}
}
for (let i = 0; i < 100 && [state.web.pid, state.api.pid].filter(pid => pid > 0).some(alive); i++) await setTimeout(100);
for (const info of [state.web, state.api]) {
  if (info.pid > 0 && alive(info.pid)) {
    try { process.kill(-info.pid, "SIGKILL"); } catch {}
  }
}
await setTimeout(300);
const left = [apiPort, webPort].map(port => [port, listenerPid(port)]).filter(([, pid]) => pid);
rmSync(statePath, { force: true }); // api.log と web.log は調査用に残し、次の起動で上書きする。
if (left.length) {
  console.error(`まだ待受が残っています: ${left.map(([port, pid]) => `${port}番 PID ${pid}`).join(", ")}。起動元を確認してから止めてください。`);
  process.exit(1);
}
console.log(`停止しました。記録 ${statePath} を削除し、証拠 ${evidenceRoot} は残しています。`);
