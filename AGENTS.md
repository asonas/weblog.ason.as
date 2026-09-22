## Agent skills

### Issue tracker

Issues are tracked in this repository's GitHub Issues. See `docs/agents/issue-tracker.md`.

### Triage labels

The canonical triage labels use their default names. See `docs/agents/triage-labels.md`.

### Domain docs

Domain documentation uses a single-context layout. See `docs/agents/domain.md`.

### Authoring design

`/authoring/*` と `/draft-editor` のUIを変更するときは、先に `frontend/authoring/DESIGN.md` を読む。管理画面専用の規範であり、公開サイトとエディタ内の公開プレビューには `docs/design-system.md` を使う。

### Terraform operations

- Run Terraform checks, plans, and applies locally. GitHub Actions must not execute Terraform.
- Use `mairu exec --no-login` with the least-privileged available role that can complete the operation. Use `282782318939/AdministratorAccess` when applying `infra/bootstrap` or `infra/production` requires account-level infrastructure permissions.
- Before every apply, initialize the target root, save a fresh plan, inspect its complete resource summary, and apply that exact saved plan.
- After every apply, run a fresh plan and confirm that no unintended changes remain.
