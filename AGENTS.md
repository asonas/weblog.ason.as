# AGENTS.md

## Git Workflow

- While the product is in its MVP phase, make changes directly on `main` and do not create a dedicated Git worktree. This temporary rule takes precedence over global worktree instructions until the user declares the MVP complete.
- After the MVP phase is complete, use a dedicated Git worktree for every new change and do not make feature changes directly on `main`.
- Before integrating a branch, rebase it onto the latest `main` branch.
- Integration into `main` must be fast-forward-only. Use `git merge --ff-only <branch>` and never create a merge commit.
- If the branch cannot be rebased cleanly or cannot be integrated with a fast-forward merge, stop and resolve the branch history before integrating it.
- After confirming that `main` contains the change, remove the temporary worktree and delete the merged branch.
