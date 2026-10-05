import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(
  new URL("./integrate-worktree.mjs", import.meta.url),
);
function git(cwd, ...args) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}
for (const failure of ["verification", "main moved", "unsigned"]) {
  test(`integration preserves branch and worktree after ${failure}`, () => {
    const directory = mkdtempSync(join(tmpdir(), "weblog-integration-"));
    const root = join(directory, "main");
    mkdirSync(root);
    const worktree = join(directory, "feature");
    try {
      git(root, "init", "-b", "main");
      git(root, "config", "user.name", "Fixture");
      git(root, "config", "user.email", "fixture@example.test");
      git(root, "config", "commit.gpgsign", "false");
      writeFileSync(join(root, "body"), "base");
      git(root, "add", "body");
      git(root, "commit", "-m", "Base");
      const base = git(root, "rev-parse", "HEAD");
      git(root, "worktree", "add", "-b", "feature", worktree);
      writeFileSync(join(worktree, "body"), "change");
      git(worktree, "commit", "-am", "Change");
      const verify =
        failure === "verification"
          ? [process.execPath, "-e", "process.exit(7)"]
          : failure === "main moved"
            ? [
                "git",
                "-C",
                root,
                "commit",
                "--allow-empty",
                "-m",
                "Concurrent work",
              ]
            : [process.execPath, "-e", "process.exit(0)"];
      const result = spawnSync(
        process.execPath,
        [script, "feature", "--", ...verify],
        { cwd: root, encoding: "utf8" },
      );
      assert.equal(result.status, 1);
      assert.ok(existsSync(worktree));
      git(root, "rev-parse", "feature");
      if (failure === "main moved") assert.match(result.stderr, /main changed/);
      else assert.equal(git(root, "rev-parse", "main"), base);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
}
