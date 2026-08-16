# Scrapbox Migration Phase 0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ScrapboxのエクスポートをNAS上のMarkdown・アセット・SQLite派生インデックスへ変換し、ウェブログモードとカードモードをローカルで検証できる状態を作る。

**Architecture:** 変換前のScrapbox JSONを不変の入力として保存し、PythonのローカルCLIで正規化データとSQLite派生インデックスを生成する。静的プレビューは同じ正規化データを読み、日付ページと記事起点のカード探索を表示する。AWSや外部サービスへ接続しない。

**Tech Stack:** Python 3.12以上3.15未満、標準ライブラリの `sqlite3`、`pytest`、`markdown-it-py`、静的HTML/CSS/JavaScript。Python実行時は `mise exec -- python3` を使う。

**Spec:** `docs/superpowers/specs/2026-08-16-scrapbox-migration-phase0.md`

## Global Constraints

- 正本は `data/normalized/posts/` のMarkdownと `data/normalized/assets/` のアセットであり、SQLiteは再生成可能な派生物とする。
- 移行入力の `data/raw/` は変更しない。
- 移行記事の公開状態は `public` を既定値とする。
- 1つのScrapboxページを初期移行では1つの記事へ変換する。
- 未解決リンクと欠落アセットを本文から黙って削除しない。
- フェーズ0の実行時にネットワークへ接続しない。
- 既存のAWS、投稿アプリ、編集履歴、音声・動画の高度な変換は実装しない。
- 変換結果は同一入力に対して決定的であること。

---

### Task 1: PythonプロジェクトとCLI契約を作る

**Files:**
- Create: `pyproject.toml`
- Create: `src/log_migration/__init__.py`
- Create: `src/log_migration/__main__.py`
- Create: `src/log_migration/cli.py`
- Create: `tests/test_cli.py`

**Interfaces:**
- Produces: `mise exec -- python3 -m log_migration --input <raw-json> --output <output-dir> --report <report-dir>`
- Returns: exit code `0` on success, non-zero on invalid input or failed conversion.

- [ ] **Step 1: Write the failing CLI tests**

```python
def test_cli_requires_input_and_output(tmp_path):
    result = run_cli([])
    assert result.returncode != 0
    assert "--input" in result.stderr


def test_cli_rejects_missing_input(tmp_path):
    result = run_cli([
        "--input", str(tmp_path / "missing.json"),
        "--output", str(tmp_path / "out"),
        "--report", str(tmp_path / "report"),
    ])
    assert result.returncode != 0
```

- [ ] **Step 2: Run the CLI tests and verify they fail**

Run: `mise exec -- python3 -m pytest tests/test_cli.py -q`

Expected: FAIL because the package and CLI entry point do not exist.

- [ ] **Step 3: Add the minimal package metadata and argument parser**

Define the `pytest` and `markdown-it-py` dependencies in `pyproject.toml`. Implement `cli.main(argv)` with required `--input`, `--output`, and `--report` arguments, existence checks, and a conversion call that is replaced by Task 2.

- [ ] **Step 4: Run the CLI tests and verify they pass**

Run: `mise exec -- python3 -m pytest tests/test_cli.py -q`

Expected: PASS.

- [ ] **Step 5: Commit the scaffold**

```bash
git add pyproject.toml src/log_migration tests/test_cli.py
git commit -m "Add migration CLI scaffold"
```

### Task 2: Scrapboxエクスポートの入力モデルを実装する

**Files:**
- Create: `src/log_migration/models.py`
- Create: `src/log_migration/scrapbox.py`
- Create: `tests/fixtures/scrapbox/minimal.json`
- Create: `tests/test_scrapbox.py`

**Interfaces:**
- Consumes: Scrapbox export JSON from `--input`.
- Produces: `ScrapboxProject` and `ScrapboxPage` immutable data objects with title, lines, source URL, optional timestamps, and source links.

- [ ] **Step 1: Add a fixture covering pages, links, images, and a missing target**

The fixture must contain one page linking to a second page, one image reference, and one unresolved page title. Keep the fixture small enough that the expected normalized result can be written inline in tests.

- [ ] **Step 2: Write failing parser tests**

```python
def test_load_export_preserves_page_titles_and_lines():
    project = load_export(FIXTURE)
    assert project.name == "asonas-memo"
    assert [page.title for page in project.pages] == ["A", "B"]
    assert project.pages[0].lines == ["本文", "[B]"]


def test_load_export_keeps_source_link_and_image_lines():
    project = load_export(FIXTURE)
    assert project.pages[0].links == ["B"]
    assert project.pages[0].asset_references == ["photo.jpg"]
```

- [ ] **Step 3: Implement strict JSON loading and normalized input objects**

Reject malformed top-level data with an error containing the input path. Do not make network requests to resolve page titles or images.

- [ ] **Step 4: Run parser tests**

Run: `mise exec -- python3 -m pytest tests/test_scrapbox.py -q`

Expected: PASS.

- [ ] **Step 5: Commit the parser**

```bash
git add src/log_migration/models.py src/log_migration/scrapbox.py tests/fixtures/scrapbox/minimal.json tests/test_scrapbox.py
git commit -m "Parse Scrapbox export fixtures"
```

### Task 3: 記事IDとMarkdown正規化を実装する

**Files:**
- Create: `src/log_migration/normalize.py`
- Create: `tests/test_normalize.py`
- Modify: `src/log_migration/cli.py`

**Interfaces:**
- Consumes: `ScrapboxProject` from Task 2.
- Produces: `data/normalized/posts/<post-id>.md`, `data/normalized/migration-map.json`, and a list of normalization issues.

- [ ] **Step 1: Write failing ID and frontmatter tests**

```python
def test_post_id_is_stable_for_same_source_key():
    first = stable_post_id("asonas-memo", "A")
    second = stable_post_id("asonas-memo", "A")
    assert first == second


def test_normalized_page_defaults_to_public():
    post = normalize_page(page(title="A", lines=["本文"]))
    assert post.frontmatter["visibility"] == "public"
    assert post.frontmatter["source_title"] == "A"
```

- [ ] **Step 2: Run the normalization tests to verify they fail**

Run: `mise exec -- python3 -m pytest tests/test_normalize.py -q`

Expected: FAIL because the ID and normalization functions do not exist.

- [ ] **Step 3: Implement deterministic IDs, frontmatter, and source mapping**

Use a stable hash of `source_project` and the original title when the export has no stable source page ID. Write the original source URL and title into frontmatter. Preserve unresolved links in the Markdown body and emit an issue instead of dropping them.

- [ ] **Step 4: Run normalization tests and inspect a generated fixture**

Run: `mise exec -- python3 -m pytest tests/test_normalize.py -q`

Expected: PASS. Inspect the generated Markdown and verify that rerunning normalization produces byte-identical files.

- [ ] **Step 5: Commit normalization**

```bash
git add src/log_migration/normalize.py src/log_migration/cli.py tests/test_normalize.py
git commit -m "Normalize Scrapbox pages into Markdown posts"
```

### Task 4: SQLite派生インデックスと逆リンクを実装する

**Files:**
- Create: `src/log_migration/index.py`
- Create: `tests/test_index.py`
- Modify: `src/log_migration/cli.py`

**Interfaces:**
- Consumes: normalized posts, assets, and explicit edge records.
- Produces: `data/index/log.sqlite3` with `posts`, `assets`, `edges`, and `issues` tables.
- Produces: `find_backlinks(target_id)` and `neighbors(root_id, direction, depth, start_date, end_date)`.

- [ ] **Step 1: Write failing graph tests**

```python
def test_backlinks_return_all_posts_referencing_an_asset(index):
    assert index.find_backlinks("asset-y") == ["post-a", "post-b"]


def test_neighbors_are_deduplicated_and_depth_limited(index):
    assert index.neighbors("post-a", direction="both", depth=1) == ["post-b"]
```

- [ ] **Step 2: Run graph tests and verify they fail**

Run: `mise exec -- python3 -m pytest tests/test_index.py -q`

Expected: FAIL because the SQLite schema and query methods do not exist.

- [ ] **Step 3: Implement the rebuildable SQLite schema**

Create tables for posts, assets, edges, and issues. Add indexes for `source_id`, `target_id`, `edge_kind`, and dates. Rebuild the database from normalized files rather than treating SQLite rows as the editable source.

- [ ] **Step 4: Implement bidirectional depth-limited traversal**

Return each node once, keep the root separately, and apply the date filter to discovered posts. Preserve edge direction in the result so the UI can label references and backlinks.

- [ ] **Step 5: Test rebuild determinism**

Delete the generated SQLite file, rebuild it twice, and compare the ordered rows in every table. The results must match.

- [ ] **Step 6: Commit the index**

```bash
git add src/log_migration/index.py src/log_migration/cli.py tests/test_index.py
git commit -m "Build rebuildable link index"
```

### Task 5: 静的プレビューでウェブログ表示を作る

**Files:**
- Create: `src/log_migration/render.py`
- Create: `src/log_migration/templates/weblog.html`
- Create: `tests/test_render.py`
- Modify: `src/log_migration/cli.py`

**Interfaces:**
- Consumes: normalized posts and the SQLite index.
- Produces: `site/index.html`, `site/YYYY-MM-DD/index.html`, and article pages with stable internal links.

- [ ] **Step 1: Write failing weblog rendering tests**

```python
def test_render_day_page_orders_public_posts_by_time(site):
    render_site(site)
    html = read_site("2026-08-15/index.html")
    assert html.index("post-a") < html.index("post-b")


def test_render_day_page_does_not_show_private_posts(site):
    render_site(site)
    html = read_site("2026-08-15/index.html")
    assert "private-post" not in html


def test_render_undated_page_contains_posts_without_created_at(site):
    render_site(site)
    html = read_site("undated/index.html")
    assert "undated-post" in html
```

- [ ] **Step 2: Run rendering tests and verify they fail**

Run: `mise exec -- python3 -m pytest tests/test_render.py -q`

Expected: FAIL because the renderer and templates do not exist.

- [ ] **Step 3: Implement Markdown rendering and date-page generation**

Render the normalized Markdown body with `markdown-it-py`. Generate one page per `created_at` date containing public posts ordered by authored time. Articles with `created_at: null` must be rendered under `site/undated/index.html` rather than assigned an inferred date.

- [ ] **Step 4: Add card placeholders for linked assets**

At each known asset reference, render a card shell containing the asset ID, type, and relation to the source post. Missing assets render an explicit unavailable state and remain present in the issue report.

- [ ] **Step 5: Run rendering tests and inspect the generated HTML**

Run: `mise exec -- python3 -m pytest tests/test_render.py -q`

Expected: PASS. Inspect the generated HTML and verify that long cards begin expanded in the first viewport and later cards have a compact representation.

- [ ] **Step 6: Commit the weblog renderer**

```bash
git add src/log_migration/render.py src/log_migration/templates/weblog.html tests/test_render.py src/log_migration/cli.py
git commit -m "Render migrated posts as a weblog"
```

### Task 6: カード探索プレビューを作る

**Files:**
- Create: `src/log_migration/templates/cards.html`
- Create: `src/log_migration/static/cards.js`
- Create: `tests/test_cards.py`
- Modify: `src/log_migration/render.py`

**Interfaces:**
- Consumes: `neighbors(root_id, direction, depth, start_date, end_date)` from Task 4.
- Produces: article-rooted card views with range presets `1d`, `7d`, `30d`, `100d`, and `all`.

- [ ] **Step 1: Write failing card traversal rendering tests**

```python
def test_card_view_includes_incoming_and_outgoing_neighbors(site):
    html = render_cards(site, root="post-a", range_name="all", depth=1)
    assert "post-a" in html
    assert "post-b" in html
    assert "post-c" in html


def test_card_view_does_not_duplicate_a_node_reached_by_two_edges(site):
    html = render_cards(site, root="post-a", range_name="all", depth=2)
    assert html.count('data-post-id="post-d"') == 1
```

- [ ] **Step 2: Run card tests and verify they fail**

Run: `mise exec -- python3 -m pytest tests/test_cards.py -q`

Expected: FAIL because card templates and traversal rendering do not exist.

- [ ] **Step 3: Implement range presets and root highlighting**

Encode the selected range and depth in the preview URL. Highlight the root card, order related cards by date, and label incoming versus outgoing edges.

- [ ] **Step 4: Add compact/expanded card state without changing document order**

Use stable card shells and client-side visibility state so expanding or compacting a card does not move already-read content unexpectedly. Respect a reduced-motion preference by disabling transitions.

- [ ] **Step 5: Add asset reverse-link display**

For an asset card, render the first few referencing posts and a count for the remaining posts. Link each entry to its article page.

- [ ] **Step 6: Run card tests and inspect all-period exploration**

Run: `mise exec -- python3 -m pytest tests/test_cards.py -q`

Expected: PASS. Verify that `all` is selectable, but the initial render caps the number of cards and exposes a continuation control.

- [ ] **Step 7: Commit card mode**

```bash
git add src/log_migration/templates/cards.html src/log_migration/static/cards.js tests/test_cards.py src/log_migration/render.py
git commit -m "Add linked card exploration preview"
```

### Task 7: 移行レポートとエンドツーエンド検証を完成させる

**Files:**
- Create: `src/log_migration/report.py`
- Create: `tests/test_report.py`
- Create: `tests/test_end_to_end.py`
- Modify: `src/log_migration/cli.py`

**Interfaces:**
- Consumes: parser, normalizer, indexer, and renderer outputs from Tasks 2-6.
- Produces: JSON and Markdown reports under the requested report directory.

- [ ] **Step 1: Write failing report tests**

```python
def test_report_counts_unresolved_links_and_missing_assets(report):
    assert report["unresolved_links"] == 1
    assert report["missing_assets"] == 1


def test_report_contains_input_hash(report):
    assert len(report["input_sha256"]) == 64
```

- [ ] **Step 2: Implement deterministic report generation**

Include input hash, run timestamp, counts, issue lists, and output paths. Sort all lists before writing so reports are stable except for the run timestamp.

- [ ] **Step 3: Add the end-to-end fixture run**

Run the CLI against `tests/fixtures/scrapbox/minimal.json` and assert that normalized Markdown, SQLite, report files, date page, and card view are all created.

- [ ] **Step 4: Run the complete phase-0 test suite**

Run: `mise exec -- python3 -m pytest -q`

Expected: PASS with zero failures.

- [ ] **Step 5: Run the same conversion twice and compare deterministic outputs**

Run the CLI twice into separate output directories and compare normalized Markdown, migration map, SQLite table contents, and report issue lists. Ignore only the report execution timestamp.

- [ ] **Step 6: Commit the phase-0 validation pipeline**

```bash
git add src/log_migration/report.py tests/test_report.py tests/test_end_to_end.py src/log_migration/cli.py
git commit -m "Complete phase zero migration validation"
```

## Verification Checklist

- [ ] `mise exec -- python3 -m pytest -q` passes.
- [ ] The raw Scrapbox export hash is unchanged after conversion.
- [ ] A page-to-post mapping is available for every imported page.
- [ ] Unresolved links and missing assets appear in the report.
- [ ] A date page renders in weblog mode.
- [ ] An article-rooted card view renders incoming and outgoing links.
- [ ] An asset card lists multiple referencing posts.
- [ ] SQLite can be deleted and rebuilt without changing rendered results.
- [ ] The pipeline makes no network request.
