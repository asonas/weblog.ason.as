// verify-weblog-authoring の共有定義。起動・診断・操作・停止の各スクリプトが読み込む。
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";

export const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
export const stateDir = resolve(root, "tmp/verify-weblog-authoring");
export const statePath = resolve(stateDir, "instance.json");
export const evidenceRoot = resolve(stateDir, "evidence");
// test/fixtures/drafts/server.rb がAPIを18082番に固定しているため、同時に起動できるのは1台だけ。
export const apiPort = 18082;
export const webPort = 15182;
export const apiBase = `http://127.0.0.1:${apiPort}`;
export const webBase = `http://127.0.0.1:${webPort}`;

export function readState() {
  if (!existsSync(statePath)) return null;
  return JSON.parse(readFileSync(statePath, "utf8"));
}

export function listenerPid(port) {
  try {
    const out = execFileSync("lsof", ["-nP", "-t", `-iTCP:${port}`, "-sTCP:LISTEN"], { encoding: "utf8" }).trim();
    return out ? Number(out.split("\n")[0]) : null;
  } catch {
    return null;
  }
}

export function processCwd(pid) {
  try {
    const out = execFileSync("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], { encoding: "utf8" });
    return out.split("\n").find(line => line.startsWith("n"))?.slice(1) ?? null;
  } catch {
    return null;
  }
}

export function alive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

export async function health(base) {
  try {
    const response = await fetch(`${base}/api/draft-test-health`);
    return response.ok ? await response.text() : null;
  } catch {
    return null;
  }
}

export function newEvidenceDir(label) {
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const dir = resolve(evidenceRoot, `${stamp}-${label}`);
  mkdirSync(dir, { recursive: true });
  return dir;
}
