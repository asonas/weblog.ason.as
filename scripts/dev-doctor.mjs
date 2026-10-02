import { accessSync, constants, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = fileURLToPath(new URL("../", import.meta.url));
let failed = false;
function run(command, args) {
  return spawnSync(command, args, { cwd: root, encoding: "utf8" });
}

console.log(`Worktree: ${root}`);
console.log(`Branch: ${run("git", ["branch", "--show-current"]).stdout?.trim() || "detached"}`);
console.log(`Node: ${process.version} (${process.execPath})`);
const ruby = run("mise", ["exec", "--", "ruby", "--version"]);
console.log(`Ruby: ${ruby.status === 0 ? ruby.stdout.trim() : "見つかりません。mise exec経由で実行してください"}`);
if (ruby.status !== 0) failed = true;

for (const entry of ["node_modules/vite/bin/vite.js", "node_modules/tsx/dist/cli.mjs"]) {
  const path = `${root}${entry}`;
  try {
    accessSync(path, constants.R_OK);
    console.log(`OK: ${entry} -> ${realpathSync(path)}`);
  } catch {
    failed = true;
    console.log(`不足: ${entry}。preview-in-worktreeの依存関係準備手順を実行してください。`);
  }
}
const bundle = run("mise", ["exec", "--", "ruby", "-S", "bundle", "check"]);
if (bundle.status !== 0) failed = true;
console.log(`Ruby dependencies: ${bundle.status === 0 ? "OK" : "不足。mise exec -- bundle install を実行してください"}`);

const listeners = run("lsof", ["-nP", "-iTCP:8000", "-sTCP:LISTEN", "-t"]);
if (listeners.error) {
  console.log("API: lsofを利用できないため起動元は未確認です。");
} else if (!listeners.stdout.trim()) {
  console.log("API: 8000番の待受なし。mainのAPI起動が必要です。");
} else {
  for (const pid of new Set(listeners.stdout.trim().split(/\s+/))) {
    const cwd = run("lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"]);
    const directory = cwd.stdout?.split("\n").find(line => line.startsWith("n"))?.slice(1);
    console.log(`API: PID ${pid}, cwd ${directory || "未確認"}。mainのworktreeか確認してください。`);
  }
}
process.exitCode = failed ? 1 : 0;
