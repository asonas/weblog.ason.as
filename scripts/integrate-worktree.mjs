import { spawnSync } from "node:child_process";

const signingKey = "735D5A50F3ED5D795B20468F06FE62FF2104E75E";
const [branch, separator, ...verification] = process.argv.slice(2);
function run(cwd, command, args) {
  const result = spawnSync(command, args, { cwd, encoding: "utf8" });
  if (result.status !== 0)
    throw new Error(
      result.stderr ||
        result.stdout ||
        result.error?.message ||
        `${command} failed`,
    );
  return result.stdout.trim();
}
function git(cwd, ...args) {
  return run(cwd, "git", args);
}
try {
  if (
    !branch ||
    separator !== "--" ||
    !verification.length ||
    branch === "main" ||
    branch.startsWith("-")
  )
    throw new Error(
      "Usage: mise exec -- node scripts/integrate-worktree.mjs <branch> -- <verification command> [args]",
    );
  const root = git(process.cwd(), "rev-parse", "--show-toplevel");
  if (git(root, "branch", "--show-current") !== "main")
    throw new Error("Run from the main worktree");
  if (git(root, "status", "--porcelain"))
    throw new Error("main worktree must be clean");
  const blocks = git(root, "worktree", "list", "--porcelain").split("\n\n");
  const block = blocks.find((value) =>
    value.split("\n").includes(`branch refs/heads/${branch}`),
  );
  const worktree = block
    ?.split("\n")
    .find((value) => value.startsWith("worktree "))
    ?.slice(9);
  if (!worktree) throw new Error("Branch must have a linked worktree");
  if (git(worktree, "status", "--porcelain"))
    throw new Error("Branch worktree must be clean");
  const main = git(root, "rev-parse", "main");
  git(
    worktree,
    "-c",
    `user.signingkey=${signingKey}`,
    "rebase",
    `--gpg-sign=${signingKey}`,
    "main",
  );
  run(worktree, verification[0], verification.slice(1));
  if (
    git(root, "rev-parse", "main") !== main ||
    git(root, "status", "--porcelain")
  )
    throw new Error(
      "main changed during verification; rebase and verify again",
    );
  if (
    git(worktree, "status", "--porcelain") ||
    git(worktree, "branch", "--show-current") !== branch
  )
    throw new Error("Verification changed the branch worktree");
  const commits = git(worktree, "rev-list", "main..HEAD")
    .split("\n")
    .filter(Boolean);
  if (!commits.length) throw new Error("No commits to integrate");
  for (const commit of commits) {
    git(worktree, "verify-commit", commit);
    if (git(worktree, "log", "-1", "--format=%GF", commit) !== signingKey)
      throw new Error(`Commit ${commit} was not signed with the AI agent key`);
  }
  git(root, "merge", "--ff-only", "--no-edit", branch);
  git(root, "merge-base", "--is-ancestor", branch, "main");
  git(root, "worktree", "remove", worktree);
  git(root, "branch", "-d", branch);
  git(root, "worktree", "prune");
  console.log(`Integrated ${branch} into main; not pushed`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
