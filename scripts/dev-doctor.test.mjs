import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

test("doctor detects a missing dependency even when Vite and tsx exist", () => {
  const root = mkdtempSync(join(tmpdir(), "weblog-doctor-"));
  try {
    mkdirSync(join(root, "scripts"));
    copyFileSync(
      new URL("./dev-doctor.mjs", import.meta.url),
      join(root, "scripts/dev-doctor.mjs"),
    );
    for (const [name, entry] of [
      ["vite", "bin/vite.js"],
      ["tsx", "dist/cli.mjs"],
    ]) {
      const directory = join(root, "node_modules", name);
      mkdirSync(join(directory, entry.split("/")[0]), { recursive: true });
      writeFileSync(
        join(directory, "package.json"),
        JSON.stringify({ name, version: "1.0.0" }),
      );
      writeFileSync(join(directory, entry), "");
    }
    writeFileSync(
      join(root, "package.json"),
      JSON.stringify({
        dependencies: { vite: "1.0.0", tsx: "1.0.0", qrcode: "1.5.4" },
      }),
    );
    const result = spawnSync(
      process.execPath,
      [join(root, "scripts/dev-doctor.mjs")],
      { encoding: "utf8" },
    );
    assert.equal(result.status, 1);
    assert.match(result.stdout, /OK: node_modules\/vite/);
    assert.match(result.stdout, /missing: qrcode/);
    assert.match(result.stdout, /Node dependencies: 不足/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
