# URL Asset Fetch Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the explicit asset downloader fetch legacy Gyazo page URLs and URLs containing Japanese characters, then store the real migration output under the repository's ignored `data/normalized` directory.

**Architecture:** Keep normal migration offline and preserve the original manifest URL. The downloader will resolve only legacy Gyazo page URLs through their `og:image` metadata, percent-encode request paths and queries at the HTTP boundary, and record the resolved fetch URL alongside successful results. General URL OGP extraction remains a later phase.

**Tech Stack:** Python 3.14, standard library (`urllib`, `html.parser`), pytest, Git worktree.

**Spec:** `docs/superpowers/specs/2026-08-16-scrapbox-url-assets-design.md`

## Global Constraints

- 通常の移行、テスト、静的表示はネットワークへ接続しない。
- `http` と `https` のURLだけを対象にする。
- 取得失敗時はエラーを記録し、manifestと本文を変更しない。
- 取得したファイルはContent-Typeと拡張子を検証し、パストラバーサルを許可しない。
- 大きすぎる応答は上限を設けて失敗として記録する。
- 外部URLの内容をMarkdownやHTMLとして解釈しない。ただし、Gyazoページの画像URL解決に必要な最小限のmeta要素だけを読む。
- 取得データは `data/normalized/assets` に保存し、`data/normalized/` のgitignoreによりバイナリをコミットしない。

---

### Task 1: Encode request URLs safely

**Files:**
- Modify: `src/log_migration/assets.py`
- Test: `tests/test_asset_fetch.py`

**Interfaces:**
- Produces: `_request_url(url: str) -> str`, which preserves valid existing escapes while percent-encoding non-ASCII path and query characters before `urlopen`.

- [ ] **Step 1: Write the failing test**

  Extend the local HTTP handler with a URL containing a Japanese path segment and add `test_fetch_assets_encodes_non_ascii_request_urls`. The handler returns `PNG_BYTES` with `Content-Type: image/png` for the percent-encoded path. The test uses the unescaped URL in the manifest and asserts one download and the expected file bytes.

- [ ] **Step 2: Run the test to verify it fails**

  Run: `mise exec -- /Users/asonas/ghq/github.com/asonas/weblog.ason.as/.venv/bin/python -m pytest -q tests/test_asset_fetch.py::test_fetch_assets_encodes_non_ascii_request_urls`

  Expected: FAIL because `urlopen` rejects the unescaped non-ASCII URL before the local handler receives it.

- [ ] **Step 3: Write the minimal implementation**

  Import `quote` and `urlunsplit`, construct a URL from `urlsplit`, quote the path with `/` and RFC-unreserved characters safe, quote the query while preserving delimiters and existing `%XX` escapes, and remove the fragment. Pass this result to every `urlopen` call without changing the manifest's original URL.

- [ ] **Step 4: Run the test to verify it passes**

  Run: `mise exec -- /Users/asonas/ghq/github.com/asonas/weblog.ason.as/.venv/bin/python -m pytest -q tests/test_asset_fetch.py::test_fetch_assets_encodes_non_ascii_request_urls`

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add src/log_migration/assets.py tests/test_asset_fetch.py
  git commit -m "encode asset request URLs"
  ```

### Task 2: Resolve legacy Gyazo page URLs

**Files:**
- Modify: `src/log_migration/assets.py`
- Test: `tests/test_asset_fetch.py`

**Interfaces:**
- Produces: `_resolve_gyazo_url(url: str, timeout: float, max_bytes: int) -> str | None`, returning the absolute `og:image` URL for a `gyazo.com/<id>` page and `None` for non-Gyazo URLs.
- Produces: successful download reports with `fetched_url` when the actual request URL differs from the manifest URL.

- [ ] **Step 1: Write the failing test**

  Extend the local HTTP handler with `/gyazo/<id>` returning HTML containing an `og:image` meta tag pointing to `/gyazo-direct/<id>.jpg`, and `/gyazo-direct/<id>.jpg` returning image bytes. Add `test_fetch_assets_resolves_gyazo_page_urls`, asserting that the manifest's original URL is retained, the direct image is saved with a `.jpg` suffix, `fetched_url` is recorded, and the SHA-256 is correct.

- [ ] **Step 2: Run the test to verify it fails**

  Run: `mise exec -- /Users/asonas/ghq/github.com/asonas/weblog.ason.as/.venv/bin/python -m pytest -q tests/test_asset_fetch.py::test_fetch_assets_resolves_gyazo_page_urls`

  Expected: FAIL because the current downloader validates the Gyazo HTML response as an image.

- [ ] **Step 3: Write the minimal implementation**

  Add a small `HTMLParser` that reads only `og:image`/`og:image:url` meta content. For `gyazo.com` and `www.gyazo.com` page URLs, fetch the page with the encoded request URL, enforce the existing byte limit, resolve the meta value with `urljoin`, then fetch and validate the resolved image using the existing Content-Type and size checks. Keep the manifest URL in `url`; set `fetched_url` to the resolved URL in successful reports. If no image meta exists, return a normal failed result without changing the manifest.

- [ ] **Step 4: Run the test to verify it passes**

  Run: `mise exec -- /Users/asonas/ghq/github.com/asonas/weblog.ason.as/.venv/bin/python -m pytest -q tests/test_asset_fetch.py::test_fetch_assets_resolves_gyazo_page_urls tests/test_asset_fetch.py`

  Expected: PASS.

- [ ] **Step 5: Commit**

  ```bash
  git add src/log_migration/assets.py tests/test_asset_fetch.py
  git commit -m "resolve Gyazo page image URLs"
  ```

### Task 3: Make repository-local storage explicit

**Files:**
- Modify: `.gitignore`
- Modify: `README.md`

**Interfaces:**
- Produces: documented commands that write the normalized migration, fetched assets, and reports under the repository's `data/` directory.

- [ ] **Step 1: Write the failing test**

  No automated test is needed for this documentation and ignore-rule change. Verify the current `.gitignore` does not protect `.worktrees/` and the README does not explain that `data/normalized/assets` is repository-local persistent working data.

- [ ] **Step 2: Make the minimal change**

  Add `.worktrees/` to `.gitignore`. Update the README asset section to show `data/normalized/assets` and `data/reports/asset-fetch-report.json`, explain that generated binaries are kept in the repository working directory but are intentionally not committed, and provide the full migration-then-fetch command sequence.

- [ ] **Step 3: Verify the documentation and ignore rule**

  Run: `git check-ignore -q .worktrees/asset-fetch-fix` and `rg -n "data/normalized/assets|asset-fetch-report" README.md`

  Expected: the ignore check succeeds and README contains the repository-local paths.

- [ ] **Step 4: Commit**

  ```bash
  git add .gitignore README.md
  git commit -m "document repository-local asset storage"
  ```

### Task 4: Validate and populate repository-local assets

**Files:**
- Create (ignored runtime data): `data/normalized/`, `data/reports/`

**Interfaces:**
- Consumes: `/Users/asonas/Downloads/asonas-memo.json`
- Produces: `data/normalized/asset-manifest.json`, `data/normalized/assets/`, and `data/reports/asset-fetch-report.json`.

- [ ] **Step 1: Run the complete test suite**

  Run: `mise exec -- /Users/asonas/ghq/github.com/asonas/weblog.ason.as/.venv/bin/python -m pytest -q`

  Expected: all tests pass.

- [ ] **Step 2: Regenerate normalized output in the repository**

  Run: `mise exec -- /Users/asonas/ghq/github.com/asonas/weblog.ason.as/.venv/bin/python -m log_migration --input /Users/asonas/Downloads/asonas-memo.json --output data/normalized --report data/reports/migration`

  Expected: the manifest is written under `data/normalized/` without modifying the input JSON.

- [ ] **Step 3: Fetch into the repository-local directory**

  Run: `mise exec -- /Users/asonas/ghq/github.com/asonas/weblog.ason.as/.venv/bin/python -m log_migration.assets --manifest data/normalized/asset-manifest.json --output data/normalized/assets --report data/reports/asset-fetch-report.json`

  Expected: successful files are stored under `data/normalized/assets/`, failures are recorded in the report, and the manifest remains unchanged.

- [ ] **Step 4: Verify the generated data**

  Run: `jq '{downloaded, failed}' data/reports/asset-fetch-report.json && du -sh data/normalized/assets && git status --short`

  Expected: the report has counts, the asset directory exists, and generated data does not appear as untracked files because the existing `data/normalized/` and `data/reports/` ignore rules cover it.

