# AGENTS.md

## Git Workflow

- Use a dedicated Git worktree for every new change. Do not make feature changes directly on `main`.
- Before integrating a branch, rebase it onto the latest `main` branch.
- Integration into `main` must be fast-forward-only. Use `git merge --ff-only <branch>` and never create a merge commit.
- If the branch cannot be rebased cleanly or cannot be integrated with a fast-forward merge, stop and resolve the branch history before integrating it.
- After confirming that `main` contains the change, remove the temporary worktree and delete the merged branch.
