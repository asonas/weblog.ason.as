# Scrapbox URL Asset Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scrapbox本文中の外部URLを内部リンクと区別して決定的なアセットmanifestへ抽出し、明示的なコマンドで取得結果を記録できるようにする。

**Architecture:** Scrapbox parserはページリンクと外部URLを分類し、normalizerは本文を保持したまま外部URLを正規化記事へ渡す。manifestは入力と正規化結果だけから生成するオフラインの派生物とし、ネットワークを使う取得処理は`log_migration.assets`の明示コマンドへ分離する。SQLite、静的カード表示、移行レポートは同じmanifest由来のURLアセット関係を参照する。

**Tech Stack:** Python 3.12以上3.15未満、標準ライブラリの`urllib.request`・`mimetypes`・`hashlib`・`http.server`、既存の`pytest`、`markdown-it-py`。通常移行・テストはネットワークへ接続しない。

**Spec:** `docs/superpowers/specs/2026-08-16-scrapbox-url-assets-design.md`

## Global Constraints

- 元のScrapbox JSONと本文中のURLを変更しない。
- 通常の移行処理はネットワークへ接続しない。
- URLの取得は明示的な`python -m log_migration.assets`実行時だけ行う。
- manifestは入力と正規化結果だけから決定的に生成する。
- URLアセットは記事をまたいで同じ固定IDを共有する。
- 取得失敗時も本文とmanifestを削除・書き換えしない。
- 外部URLの内容をMarkdownまたはHTMLとして解釈しない。
- 既存のCLI引数と既存テストを壊さない。

---

### Task 1: Scrapbox本文のリンク分類を修正する

**Files:**
- Modify: `src/log_migration/models.py`
- Modify: `src/log_migration/scrapbox.py`
- Create: `tests/test_url_references.py`
- Modify: `tests/test_scrapbox.py`

**Interfaces:**
- `ScrapboxPage.external_urls: tuple[str, ...]` — ページ本文に含まれる重複排除済みの外部URL。
- `load_export(path: Path) -> ScrapboxProject` —既存の入力契約を維持する。

- [ ] **Step 1: 外部URL分類の失敗テストを書く**

テスト用JSONに、内部リンク、未解決候補、裸URL、`[URL ラベル]`形式を含める。次を検証する。

```python
def test_load_export_separates_page_links_and_external_urls(tmp_path):
    export = {
        "projectName": "memo",
        "pages": [{
            "title": "A",
            "lines": [
                {"text": "[B]"},
                {"text": "[https://gyazo.com/abc image] https://gyazo.com/abc"},
                {"text": "[missing]"},
            ],
        }, {"title": "B", "lines": []}],
    }
    path = tmp_path / "export.json"
    path.write_text(json.dumps(export), encoding="utf-8")

    project = load_export(path)

    assert project.pages[0].links == ("B", "missing")
    assert project.pages[0].external_urls == ("https://gyazo.com/abc",)
```

- [ ] **Step 2: テストが期待どおり失敗することを確認する**

Run: `mise exec -- .venv/bin/python -m pytest tests/test_url_references.py -q`

Expected: `AttributeError`または`external_urls`未定義による失敗。

- [ ] **Step 3: URL抽出とページモデルを実装する**

`ScrapboxPage`へ`external_urls`を追加し、角括弧の内容と裸URLを同じ抽出器で処理する。URLを含む角括弧は内部リンク候補へ追加せず、URLだけを保存する。URL末尾のMarkdown/文章由来の句読点は除去し、抽出順を保持したまま重複を除去する。

- [ ] **Step 4: 対象テストと既存parserテストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/test_url_references.py tests/test_scrapbox.py -q`

Expected: PASS。

- [ ] **Step 5: 変更をコミットする**

```sh
git add src/log_migration/models.py src/log_migration/scrapbox.py tests/test_url_references.py tests/test_scrapbox.py
git commit -m "separate external URLs from page links"
```

### Task 2: URLアセットIDとmanifestを生成する

**Files:**
- Modify: `src/log_migration/normalize.py`
- Create: `src/log_migration/asset_manifest.py`
- Create: `tests/support.py`
- Create: `tests/test_asset_manifest.py`

**Interfaces:**
- `canonicalize_url(url: str) -> str` — HTTP(S) URLのスキーム・ホストを正規化し、fragmentを除去する。
- `stable_url_asset_id(url: str) -> str` — canonical URLのSHA-256先頭16桁から`asset_` IDを返す。
- `classify_url(url: str) -> str` —`image`・`audio`・`video`・`url`のいずれかを返す。
- `AssetManifestEntry` —`id: str`、`url: str`、`kind: str`、`source_post_ids: tuple[str, ...]`を持つ不変データ。
- `build_asset_manifest(normalized: NormalizationResult) -> tuple[AssetManifestEntry, ...]` — URLごとに統合し、ID順に返す。
- `write_asset_manifest(output_dir: Path, normalized: NormalizationResult) -> Path` —`asset-manifest.json`を決定的に書く。
- `tests.support.normalized_result_with_external_urls(*url_groups) -> NormalizationResult` —記事ID`post-a`、`post-b`を持つテスト用正規化結果を作る。

- [ ] **Step 1: manifestと外部URL保持の失敗テストを書く**

同じURLを2記事が参照するケース、fragment違い、Gyazo URL、音声拡張子を使い、次を検証する。

```python
def test_manifest_deduplicates_canonical_urls_and_keeps_sources(tmp_path):
    normalized = normalized_result_with_external_urls(
        ("https://gyazo.com/abc#top",),
        ("https://gyazo.com/abc", "https://example.test/voice.mp3"),
    )

    entries = build_asset_manifest(normalized)

    assert len(entries) == 2
    gyazo = next(entry for entry in entries if entry.url == "https://gyazo.com/abc")
    assert gyazo.kind == "image"
    assert gyazo.source_post_ids == ("post-a", "post-b")
```

テストヘルパーは各URLグループを1記事として次のfrontmatterを使う。`external_urls`以外の参照は空にし、テスト対象をURLアセットへ限定する。

```python
def normalized_result_with_external_urls(*url_groups):
    posts = tuple(
        NormalizedPost(
            id=f"post-{chr(ord('a') + index)}",
            frontmatter={
                "title": f"Post {index}",
                "source_project": "memo",
                "created_at": None,
                "updated_at": None,
                "published_at": None,
                "visibility": "public",
            },
            body="",
            links=(),
            asset_references=(),
            external_urls=tuple(urls),
            issues=(),
        )
        for index, urls in enumerate(url_groups)
    )
    return NormalizationResult(posts=posts, mapping={}, issues=())
```

- [ ] **Step 2: manifestテストが失敗することを確認する**

Run: `mise exec -- .venv/bin/python -m pytest tests/test_asset_manifest.py -q`

Expected: `ModuleNotFoundError`または`external_urls`未定義による失敗。

- [ ] **Step 3: 正規化モデルへ外部URLを渡し、manifest生成を実装する**

`NormalizedPost`へ`external_urls`を追加し、`normalize_page`でページの外部URLを保持する。canonical URLは`urlsplit`で処理し、HTTP(S)以外はmanifest対象から除外して`invalid_external_url` issueにする。画像種別では`gyazo.com`・`i.gyazo.com`を既知ホストとして扱い、その他はURLパスの拡張子と`mimetypes`で推測する。

- [ ] **Step 4: manifest JSON出力と決定性を実装する**

`write_asset_manifest`は次の形でUTF-8 JSONを出力する。

```json
{
  "assets": [
    {
      "id": "asset_...",
      "url": "https://example.test/image.png",
      "kind": "image",
      "source_post_ids": ["post-a"]
    }
  ]
}
```

配列と`source_post_ids`はソートし、同じ入力の2回の出力がバイト一致することをテストする。

- [ ] **Step 5: テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/test_asset_manifest.py tests/test_normalize.py -q`

Expected: PASS。

- [ ] **Step 6: 変更をコミットする**

```sh
git add src/log_migration/normalize.py src/log_migration/asset_manifest.py tests/test_asset_manifest.py
git commit -m "build deterministic URL asset manifests"
```

### Task 3: SQLite・静的表示・移行レポートへURLアセットを接続する

**Files:**
- Modify: `src/log_migration/index.py`
- Modify: `src/log_migration/render.py`
- Modify: `src/log_migration/report.py`
- Modify: `src/log_migration/cli.py`
- Modify: `tests/test_index.py`
- Modify: `tests/test_render.py`
- Modify: `tests/test_report.py`
- Modify: `tests/test_end_to_end.py`

**Interfaces:**
- `build_index` —外部URLごとに`post -> asset`の`external_url` edgeを作る。
- `render_site` —外部URLをURLカードのフォールバックとして表示する。
- `build_report` —`external_url_candidates`とmanifest出力先を含める。
- `cli.main` —通常移行で`asset-manifest.json`を生成する。ネットワークは使わない。

- [ ] **Step 1: URLアセット接続の失敗テストを書く**

既存fixtureに外部URLを持つ記事を追加するテスト用正規化結果を作り、次を検証する。

```python
def test_index_and_render_include_external_url_asset(tmp_path):
    normalized = normalized_result_with_external_urls(("https://example.test/image.png",))
    index = build_index(normalized, tmp_path / "log.sqlite3")
    asset_id = stable_url_asset_id("https://example.test/image.png")

    assert index.find_backlinks(asset_id) == ["post-a"]
    html = render_cards(normalized, index, root_id="post-a")
    assert f'data-asset-id="{asset_id}"' in html
    assert "example.test" in html
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `mise exec -- .venv/bin/python -m pytest tests/test_index.py tests/test_render.py -q`

Expected: URLアセットのedgeまたはHTMLが存在せず失敗。

- [ ] **Step 3: インデックスとrendererへ外部URLを追加する**

外部URLをmanifestと同じIDで`assets`へ登録し、`external_url` edgeを追加する。ウェブログとカード表示では本文中のURLを保持したまま、URL、ドメイン、推測種別を表示する。URLカードは取得済みファイルがない場合のフォールバックとして機能させる。

- [ ] **Step 4: CLIとレポートを接続する**

通常移行後に`write_asset_manifest`を呼び出し、レポートへ次を追加する。

- manifest内のアセット候補数
- URL種別ごとの件数
- manifest出力パス
- `invalid_external_url`一覧

- [ ] **Step 5: 接続テストと全テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/test_index.py tests/test_render.py tests/test_report.py tests/test_end_to_end.py -q`

Expected: PASS。

- [ ] **Step 6: 変更をコミットする**

```sh
git add src/log_migration/index.py src/log_migration/render.py src/log_migration/report.py src/log_migration/cli.py tests/test_index.py tests/test_render.py tests/test_report.py tests/test_end_to_end.py
git commit -m "show URL assets in migration outputs"
```

### Task 4: 明示的なアセット取得コマンドを実装する

**Files:**
- Create: `src/log_migration/assets.py`
- Create: `tests/test_asset_fetch.py`
- Modify: `README.md`

**Interfaces:**
- `fetch_assets(manifest_path: Path, output_dir: Path, report_path: Path, timeout: float = 20.0, max_bytes: int = 50 * 1024 * 1024) -> dict[str, object]` —manifestを変更せずに取得レポートを返す。
- `python -m log_migration.assets --manifest ... --output ... --report ...` —明示的なネットワーク取得CLI。

- [ ] **Step 1: localhost HTTPサーバーを使う失敗テストを書く**

テスト内の`http.server.ThreadingHTTPServer`で、成功するPNG応答、404応答、画像種別と異なる`text/html`応答を提供する。外部サイトへ接続しない。

```python
def test_fetch_assets_writes_success_and_failure_records(tmp_path, local_asset_server):
    manifest = write_manifest(tmp_path, [
        entry("image", local_asset_server.url("/image.png"), "asset-image"),
        entry("url", local_asset_server.url("/missing"), "asset-missing"),
    ])

    report = fetch_assets(manifest, tmp_path / "assets", tmp_path / "fetch.json")

    assert report["downloaded"] == 1
    assert report["failed"] == 1
    assert (tmp_path / "assets" / "asset-image.png").read_bytes() == PNG_BYTES
```

テストはmanifestを`{"assets": [{"id": ..., "url": ..., "kind": ..., "source_post_ids": []}]}`として一時ファイルへ書き、ローカルサーバーを`("127.0.0.1", 0)`で起動する。`/image.png`は`Content-Type: image/png`と固定バイト列を返し、`/missing`は404を返す。テスト終了時に`shutdown()`と`server_close()`を呼ぶ。

- [ ] **Step 2: downloaderテストが失敗することを確認する**

Run: `mise exec -- .venv/bin/python -m pytest tests/test_asset_fetch.py -q`

Expected: `ModuleNotFoundError`または`fetch_assets`未定義による失敗。

- [ ] **Step 3: manifest読込と安全なHTTP取得を実装する**

`urllib.request.urlopen`でHTTP(S)だけを取得し、HTTPエラー・URL不正・タイムアウト・最大サイズ超過を個別に失敗記録へ変換する。保存ファイル名はmanifestのIDとMIME/URL拡張子から安全に決め、取得内容のSHA-256を計算する。

- [ ] **Step 4: MIME不一致と失敗時の不変性を実装する**

`image`・`audio`・`video`のmanifest種別に対して、応答の`Content-Type`が対応しない場合は保存せず失敗とする。`url`種別はHTMLを含む任意のContent-Typeを許可する。manifestと正規化Markdownは変更しない。

- [ ] **Step 5: CLIとREADMEを追加する**

READMEへ次の実行例と、ネットワークアクセスを伴う明示操作であることを記載する。

```sh
mise exec -- .venv/bin/python -m log_migration.assets \
  --manifest data/normalized/asset-manifest.json \
  --output data/normalized/assets \
  --report data/reports/asset-fetch-report.json
```

- [ ] **Step 6: downloaderテストと全テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/test_asset_fetch.py -q`

Run: `mise exec -- .venv/bin/python -m pytest -q`

Expected: 既存テストを含めて全件PASS。

- [ ] **Step 7: 変更をコミットする**

```sh
git add src/log_migration/assets.py tests/test_asset_fetch.py README.md
git commit -m "add explicit URL asset fetching"
```

### Task 5: 実データ検証と最終確認を行う

**Files:**
- Modify: `tests/test_end_to_end.py`
- Modify: `README.md`

**Interfaces:**
- `asonas-memo.json`はリポジトリへコピーせず、ローカルの入力として使う。
- 通常移行の出力に`asset-manifest.json`が含まれ、URL候補数がレポートに出る。

- [ ] **Step 1: 実データを一時ディレクトリへ変換する**

Run:

```sh
mise exec -- .venv/bin/python -m log_migration \
  --input /Users/asonas/Downloads/asonas-memo.json \
  --output /private/tmp/asonas-memo-normalized-v2 \
  --report /private/tmp/asonas-memo-report-v2
```

- [ ] **Step 2: manifestとレポートを確認する**

`asset-manifest.json`の件数、Gyazo URL、記事側の参照元、未解決内部リンク件数を確認する。URLを内部リンクとして数えていないことを確認する。

- [ ] **Step 3: 実データ用の最終回帰を実行する**

Run: `mise exec -- .venv/bin/python -m pytest -q`

Expected: 全テストPASS。元JSONのSHA-256は変換前後で一致する。

- [ ] **Step 4: 変更をコミットする**

```sh
git add tests/test_end_to_end.py README.md
git commit -m "validate URL assets against Scrapbox export"
```

## Verification Checklist

- [ ] URLを含む角括弧が未解決内部リンクに算入されない。
- [ ] 裸URLと角括弧内URLがmanifestで重複しない。
- [ ] 同一URLの参照元記事がmanifestとSQLiteに集約される。
- [ ] 通常移行はネットワークへ接続しない。
- [ ] 取得失敗はmanifest・本文を壊さずレポートへ残る。
- [ ] 取得内容のMIMEタイプ、保存先、SHA-256が記録される。
- [ ] 実データでGyazo URLがアセット候補として抽出される。
- [ ] `mise exec -- .venv/bin/python -m pytest -q` が通る。
