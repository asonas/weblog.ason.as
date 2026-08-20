# Weblog Authoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 開発マシンのlocalhostでMarkdown記事を書き、Wikiリンクと逆リンクを自動構築し、明示的な操作で安全に静的公開できる投稿インターフェースを実装する。

**Architecture:** 既存のScrapbox移行コードとは別に `log_migration.authoring` パッケージを追加する。`content/` のMarkdownとfrontmatterを正本にし、`data/index/authoring.sqlite3` は走査結果から再生成する派生インデックスとする。localhostの管理画面は標準ライブラリのWSGIサーバーで提供し、公開操作では候補スナップショットから `site/` をステージング生成して成功時だけ差し替える。

**Tech Stack:** Python 3.12以上3.15未満、標準ライブラリの `wsgiref`、SQLite、`markdown-it-py`、`mdit-py-plugins`、PyYAML、Pygments、プレーンHTML/CSS/JavaScript、pytest。

**Spec:** `docs/superpowers/specs/2026-08-20-weblog-authoring-design.md`

## Global Constraints

- 初期実装はlocalhostだけで動作させ、LAN公開、認証、AWS、S3、CloudFront、Lambda、外部公開用APIは実装しない。
- `content/` のMarkdownとfrontmatterを正本とし、SQLiteは再生成可能な派生インデックスにする。
- 既存の `data/normalized/` 以下の移行生成物は読み取り専用にする。
- 日付ページはAsia/Tokyoの日付ごとに一つだけ作成し、URLとファイル名を `/yyyy-mm-dd` と `content/yyyy-mm-dd.md` に固定する。
- 名前付きページはページ名を表示タイトルとして `/page-a` のようなURLを持ち、名前の大文字・小文字を区別する。
- Wikiリンクは `[[page-a]]` 形式だけを対象にし、存在しない保存済みリンク先は空の下書きページとして作成する。
- 編集画面はMarkdown入力欄とライブプレビューの分割表示にし、記事単体のプレビュー機能は追加しない。
- localhost上のWikiリンクは新しいタブ、公開サイト上のWikiリンクは同じタブで開く。
- Markdown解析エラーは下書き保存を許可するが、公開を拒否する。壊れたfrontmatterやMarkdownは自動修正・上書きしない。
- 初回保存は `draft` とし、公開は明示操作、確認、静的生成の成功を条件にする。
- 公開生成はステージング後の原子的な差し替えとし、失敗時は以前の公開出力を保持する。
- 削除、画像・ファイル添付、手動の関係タイプ、カードモード編集、認証、LAN公開は実装しない。
- 実行前に `command -v python3` と `python3 --version` を確認し、Pythonの実行は `mise exec --` 経由にする。
- コミットメッセージは英語で、Conventional Commits形式を使わず、先頭を大文字にする。

## File and module map

投稿機能は既存の `src/log_migration/index.py` と `src/log_migration/render.py` の責務を拡張せず、次の境界に分ける。

- `src/log_migration/authoring/models.py`: ページ、文書、リンク、エラー、保存・公開リクエストの型。
- `src/log_migration/authoring/names.py`: ページ名の検証、日付判定、URL・ファイルパス変換。
- `src/log_migration/authoring/frontmatter.py`: frontmatterの厳格な読み書き。
- `src/log_migration/authoring/links.py`: Wikiリンクの抽出、本文置換、リネーム時のリンク更新。
- `src/log_migration/authoring/repository.py`: `content/` の走査、正本ファイルの保存、ファイルトランザクション。
- `src/log_migration/authoring/database.py`: 投稿用SQLiteスキーマと再構築・検索・逆リンク。
- `src/log_migration/authoring/markdown.py`: Markdown拡張、Wikiリンク、コードハイライト。
- `src/log_migration/authoring/publisher.py`: 公開ページ、空プレースホルダー、リダイレクトの静的生成と差し替え。
- `src/log_migration/authoring/service.py`: 保存、公開、非公開化、リネーム、プレビューの調整。
- `src/log_migration/authoring/web.py`: WSGIアプリ、管理画面、編集画面、localhost閲覧、JSON API。
- `src/log_migration/authoring/cli.py` と `__main__.py`: localhostサーバー起動コマンド。
- `src/log_migration/templates/authoring/` と `src/log_migration/static/authoring/`: HTML、CSS、JavaScript。
- `tests/authoring/support.py`: 固定時計、repository/service、snapshot、HTTP応答を作る共通fixture。
- `tests/authoring/`: 投稿機能の単体、API、公開生成、E2Eテスト。

生成物は `content/`、`data/index/authoring.sqlite3`、`site/` に置く。`content/` は実行時に作成し、記事が保存されるまでMarkdownを作らない。SQLiteと静的サイトは既存のignore対象を使う。

## Task 1: Authoring dependencies and document primitives

**Files:**
- Modify: `pyproject.toml`
- Create: `src/log_migration/authoring/__init__.py`
- Create: `src/log_migration/authoring/models.py`
- Create: `src/log_migration/authoring/names.py`
- Create: `src/log_migration/authoring/frontmatter.py`
- Create: `src/log_migration/authoring/links.py`
- Create: `tests/authoring/__init__.py`
- Create: `tests/authoring/support.py`
- Create: `tests/authoring/test_names.py`
- Create: `tests/authoring/test_frontmatter.py`
- Create: `tests/authoring/test_links.py`

**Interfaces:**
- `PageType = Literal["date", "named"]`、`Status = Literal["draft", "published"]`。
- `PageDocument`、`PageProblem`、`WikiLink`、`Redirect`、`SaveRequest`、`PublishRequest` dataclass。`PageDocument.display_title` は名前付きページでは名前、日付ページでは任意タイトルまたは日付を返す。
- `ConflictError` と `PublishError` は変更を開始できない競合・公開失敗を表す例外。
- `validate_page_name(name: str) -> str`、`encoded_page_name(name: str) -> str`、`page_path(content_dir: Path, page_type: PageType, name: str | None, page_date: date | None) -> Path`。
- `parse_document(path: Path, text: str) -> PageDocument | PageProblem`、`serialize_document(document: PageDocument) -> str`。
- `extract_wiki_links(body: str) -> tuple[WikiLink, ...]`、`replace_wiki_links(body: str, old_name: str, new_name: str) -> str`。

- [ ] **Step 1: 依存関係と環境を追加する**

`pyproject.toml` の通常依存へ次を追加し、既存pytest設定は維持する。

```toml
"mdit-py-plugins>=0.4,<1",
"PyYAML>=6,<7",
"Pygments>=2.18,<3",
```

```sh
command -v python3
python3 --version
mise exec -- python3 -m venv .venv
mise exec -- .venv/bin/python -m pip install -e '.[test]'
```

- [ ] **Step 2: ページ名、frontmatter、Wikiリンクの失敗テストを書く**

`test_names.py` では `page-a`、Unicodeと空白、空文字、`/ ? #`、改行、制御文字、`yyyy-mm-dd` 形式、日付ファイルパスを検証する。`test_frontmatter.py` では日付ページと名前付きページのround-trip、未知status、必須ID欠落を検証する。`test_links.py` では `[[ page-a ]]` の空白除去、コードフェンス内の無視、`page-a` と `page-ab` の完全一致置換を検証する。

```python
def test_named_page_path_is_url_encoded_and_date_path_is_fixed(tmp_path):
    assert encoded_page_name("page-a") == "page-a"
    assert encoded_page_name("日本語 page") == "%E6%97%A5%E6%9C%AC%E8%AA%9E%20page"
    assert page_path(tmp_path, "named", "page-a", None) == tmp_path / "page-a.md"
    assert page_path(tmp_path, "date", None, date(2026, 1, 1)) == tmp_path / "2026-01-01.md"


def test_replace_wiki_links_does_not_replace_prefix_matches():
    assert replace_wiki_links("[[page-a]] [[page-ab]]", "page-a", "page-b") == "[[page-b]] [[page-ab]]"
```

- [ ] **Step 3: 文書の最小実装を書く**

`names.py` は `urllib.parse.quote(name, safe="-._~")` で可逆なファイル名を作り、予約名と構文衝突文字を拒否する。`frontmatter.py` は `yaml.safe_load` でfrontmatterを読み、必須キーと型を検証し、本文をそのまま保持する。`links.py` は行単位でフェンス状態を追跡し、`[[...]]` の範囲とtrim後の名前を返す。

- [ ] **Step 4: 対象テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/authoring/test_names.py tests/authoring/test_frontmatter.py tests/authoring/test_links.py -q`

Expected: すべてPASS。

- [ ] **Step 5: 共通テストfixtureを定義する**

`tests/authoring/support.py` に `fixed_clock() -> datetime`、`repository_for(tmp_path) -> ContentRepository`、`service_for(tmp_path, fail_static_build: bool = False) -> AuthoringService`、`new_date_request(page_date: date, body: str = "") -> SaveRequest` を定義する。後続テストで使う `repository_with_date_page`、`snapshot_with_published_link_to_empty_page`、`service_with_published_page`、`edit_request`、`publish_request`、`page_id_for`、`read_source`、`public_exists` はこのファイルに置き、すべて一時ディレクトリ配下だけを操作する。

- [ ] **Step 6: コミットする**

```sh
git add pyproject.toml src/log_migration/authoring tests/authoring
git commit -m "Add authoring document primitives"
```

## Task 2: Content repository and rebuildable SQLite index

**Files:**
- Create: `src/log_migration/authoring/repository.py`
- Create: `src/log_migration/authoring/database.py`
- Create: `tests/authoring/test_repository.py`
- Create: `tests/authoring/test_database.py`

**Interfaces:**
- `ContentRepository(content_dir: Path, database_path: Path, clock: Callable[[], datetime])`。
- `refresh() -> RepositorySnapshot` は `content/*.md` を走査し、正本からインデックスを再構築する。日時はAsia/Tokyoのaware datetimeとして扱う。`RepositorySnapshot` は `pages`、`problems`、`redirects` を持ち、`with_redirect(old_route: str, new_route: str) -> RepositorySnapshot` を返す。
- `get_page(page_id: str) -> PageDocument | None`、`find_route(route: str) -> PageDocument | None`、`list_pages(query: str = "", status: Status | None = None, empty_only: bool = False) -> tuple[PageDocument, ...]`。
- `save_draft(request: SaveRequest) -> PageDocument`、`rename_named_page(page_id: str, new_name: str) -> PageDocument`。
- `AuthoringDatabase.rebuild(snapshot: RepositorySnapshot) -> None`、`backlinks(target_id: str, public_only: bool) -> tuple[PageDocument, ...]`、`search(query: str, status: Status | None) -> tuple[PageDocument, ...]`。
- `RepositorySnapshot` の `pages` は有効な `PageDocument`、`problems` は `PageProblem`、`redirects` は `Redirect` のtupleとし、壊れた文書を有効ページとして公開対象へ混ぜない。

- [ ] **Step 1: 走査、保存、重複、外部編集の失敗テストを書く**

初回の日付保存が `content/yyyy-mm-dd.md` だけを作ること、同日二重保存が `ConflictError` になること、`[[page-a]]` 保存で空のdraftファイルが作られること、壊れたfrontmatterを再走査しても元ファイルを上書きしないことを検証する。

```python
def test_second_date_page_for_same_day_is_rejected(tmp_path):
    repo = repository_with_date_page(tmp_path, date(2026, 1, 1))
    with pytest.raises(ConflictError, match="2026-01-01"):
        repo.save_draft(new_date_request(date(2026, 1, 1)))


def test_invalid_external_document_is_reported_without_overwrite(tmp_path):
    path = tmp_path / "content" / "2026-01-01.md"
    path.parent.mkdir()
    original = "---\\nstatus: broken\\n---\\n本文\\n"
    path.write_text(original, encoding="utf-8")
    snapshot = repository_for(tmp_path).refresh()
    assert snapshot.problems[0].path == path
    assert path.read_text(encoding="utf-8") == original
```

- [ ] **Step 2: SQLiteスキーマを実装する**

`pages` に `id`、`page_type`、`name`、`page_date`、`title`、`status`、`created_at`、`updated_at`、`published_at`、`path`、`body_hash`、`is_empty` を保存する。`links` は `source_id`、`target_id`、`target_name`、`position` を主キー付きで保存し、`problems` は壊れたファイルのpathとdetailを保存する。DBは毎回Markdownから再構築し、本文はDBへ保存しない。

- [ ] **Step 3: 保存とファイルトランザクションを実装する**

保存前に日付の一意性、名前の一意性、ファイルシステム上の衝突、内部IDの重複を検証する。`FileTransaction` は変更前のバイト列と作成ファイルを記録し、同名の一時ファイルへfsyncして `os.replace` する。失敗時は変更前へ復元する。リネームでは対象Markdown、リンク元Markdown、frontmatter、旧パス、新パスを同じトランザクションで変更する。

- [ ] **Step 4: 対象テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/authoring/test_repository.py tests/authoring/test_database.py -q`

Expected: すべてPASS。日付重複、空ページ生成、外部編集の無上書き、SQLite削除後の再構築、リネーム衝突を確認する。

- [ ] **Step 5: コミットする**

```sh
git add src/log_migration/authoring/repository.py src/log_migration/authoring/database.py tests/authoring/test_repository.py tests/authoring/test_database.py
git commit -m "Add content repository and index"
```

## Task 3: Markdown rendering and page view models

**Files:**
- Create: `src/log_migration/authoring/markdown.py`
- Create: `tests/authoring/test_markdown.py`

**Interfaces:**
- `render_markdown(body: str, *, mode: Literal["local", "public"]) -> RenderedBody`。
- `RenderedBody` は `html`、抽出した `links`、`problems` を持つ。
- `render_page(page: PageDocument, backlinks: tuple[PageDocument, ...], *, mode: Literal["local", "public"]) -> str`。

- [ ] **Step 1: Markdown拡張とリンクターゲットの失敗テストを書く**

表、タスクリスト、取り消し線、言語付きコードブロック、生HTMLの無効化、localの `target="_blank"`、publicの同一タブを検証する。

```python
def test_local_markdown_has_extensions_and_safe_wiki_link():
    html = render_markdown("| A | B |\\n| --- | --- |\\n| 1 | 2 |\\n\\n- [ ] todo\\n\\n~~old~~\\n\\n[[page-a]]", mode="local").html
    assert "<table>" in html
    assert "type=\"checkbox\"" in html
    assert "<del>old</del>" in html
    assert 'href="/page-a"' in html and 'target="_blank"' in html
    assert "<script>" not in render_markdown("<script>alert(1)</script>", mode="local").html
```

- [ ] **Step 2: Markdownレンダラーを実装する**

`MarkdownIt("default", {"breaks": True, "html": False})` を使い、`mdit_py_plugins.tasklists.tasklists` を登録する。Pygmentsのhighlight callbackで既知言語をハイライトし、未知言語はエスケープ済みコードへフォールバックする。Wikiリンクは内部センチネルURLへ変換してからMarkdownを処理し、出力後にページURLへ戻す。localだけリンクへ `target="_blank"` と `rel="noreferrer"` を付ける。

- [ ] **Step 3: 対象テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/authoring/test_markdown.py -q`

Expected: すべてPASS。生HTMLが実行可能な形で出力されず、local/publicのリンク動作が分かれる。

- [ ] **Step 4: コミットする**

```sh
git add src/log_migration/authoring/markdown.py tests/authoring/test_markdown.py
git commit -m "Add authoring markdown renderer"
```

## Task 4: Atomic static publisher

**Files:**
- Create: `src/log_migration/authoring/publisher.py`
- Create: `src/log_migration/templates/authoring/public.html`
- Create: `tests/authoring/test_publisher.py`

**Interfaces:**
- `StaticPublisher(output_dir: Path)`。
- `build(snapshot: RepositorySnapshot, destination: Path) -> None`。
- `swap(destination: Path) -> None`。
- `publish(snapshot: RepositorySnapshot) -> None`。

- [ ] **Step 1: 公開対象の失敗テストを書く**

公開済み本文だけを出力し、draft本文を出力しないこと、公開ページから参照された空または非公開ページをプレースホルダーとして出力すること、公開済みページからの逆リンクだけを表示することを検証する。物理ファイルは `site/<encoded-route>/index.html` とする。

```python
def test_build_excludes_draft_body_and_includes_referenced_empty_page(tmp_path):
    snapshot = snapshot_with_published_link_to_empty_page()
    destination = tmp_path / "next-site"
    StaticPublisher(tmp_path / "site").build(snapshot, destination)
    assert "公開本文" in (destination / "2026-01-01" / "index.html").read_text()
    assert "まだ内容がありません" in (destination / "page-a" / "index.html").read_text()
    assert "下書き本文" not in "".join(path.read_text() for path in destination.rglob("*.html"))
```

- [ ] **Step 2: 静的ページ、空ページ、逆リンク、リダイレクトを実装する**

公開ページはタイトル、本文、公開逆リンクを含める。公開ページから参照されるdraftまたは空ページは本文を読まず、ページ名と「まだ内容がありません」、公開逆リンクだけを出力する。draftだけから参照されるページは出力しない。公開済み名前付きページのリネームでは旧routeに新URLへの静的redirect HTMLを生成し、draftのリネームでは生成しない。

`snapshot.problems` に公開対象の壊れたfrontmatterまたはMarkdownが含まれる場合は `PublishError` を返し、問題を無視して部分的なsiteを作らない。公開対象外のdraft問題は管理画面へ残すが、無関係な公開ページの生成は妨げない。

- [ ] **Step 3: ステージング差し替えの失敗テストを書く**

既存siteにmarkerを置き、差し替え処理を失敗させてもmarkerが残ること、初回生成失敗時に空のsiteを作らないことを検証する。

- [ ] **Step 4: 原子的な差し替えを実装する**

`publish()` は `site.staging-<uuid>` を作り、`build()` 成功後だけ既存siteを `site.previous-<uuid>` へ退避し、stagingを `site` へ `os.replace` する。失敗時はpreviousを復元し、stagingとpreviousを掃除する。旧公開出力を差し替える前に生成エラーを返す。

- [ ] **Step 5: 対象テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/authoring/test_publisher.py -q`

Expected: すべてPASS。draft非公開、空プレースホルダー、公開逆リンク、redirect、旧site保持を確認する。

- [ ] **Step 6: コミットする**

```sh
git add src/log_migration/authoring/publisher.py src/log_migration/templates/authoring/public.html tests/authoring/test_publisher.py
git commit -m "Add atomic static publisher"
```

## Task 5: Authoring service and publication state transitions

**Files:**
- Create: `src/log_migration/authoring/service.py`
- Create: `tests/authoring/test_service.py`

**Interfaces:**
- `AuthoringService(repository: ContentRepository, database: AuthoringDatabase, publisher: StaticPublisher, clock: Callable[[], datetime])`。
- `save_draft(request: SaveRequest) -> PageDocument`。
- `preview(request: SaveRequest, mode: Literal["local", "public"] = "local") -> RenderedBody`。
- `publish(request: PublishRequest) -> PublishResult`。
- `unpublish(page_id: str) -> PageDocument`。
- `rename(page_id: str, new_name: str) -> PageDocument`。

- [ ] **Step 1: ステータス遷移の失敗テストを書く**

新規公開の静的生成失敗時にMarkdown・DB・siteを作らないこと、公開済みページの編集保存ではlocalhostだけが新内容になること、再公開で `published_at` を維持すること、非公開化した参照先を空プレースホルダーにすることを検証する。

```python
def test_new_publish_failure_does_not_create_page_or_public_output(tmp_path):
    service = service_for(tmp_path, fail_static_build=True)
    request = new_date_request(date(2026, 1, 1), body="本文")
    with pytest.raises(PublishError):
        service.publish(request)
    assert service.repository.find_route("/2026-01-01") is None
    assert not (tmp_path / "site").exists()


def test_republish_preserves_first_published_at(tmp_path):
    service = service_with_published_page(tmp_path, body="公開版")
    published_at = service.page.published_at
    service.publish(edit_request(service, body="更新版"))
    assert service.repository.get_page(service.page.id).published_at == published_at
```

- [ ] **Step 2: 公開候補を作るサービス処理を実装する**

`publish()` は入力内容を候補スナップショットへ反映し、既存ページのIDと作成日時を維持する。新規ページには内部IDと作成日時を生成する。初回公開時だけ `published_at` を設定し、再公開では維持する。候補へ `StaticPublisher.build()` を実行し、成功後に `FileTransaction` でMarkdownを保存して `StaticPublisher.swap()` を実行する。生成失敗時は新規ページを作らず、既存Markdownとsiteを変更しない。

プレビューのMarkdown解析エラーは `RenderedBody.problems` として返し、保存は許可する。公開候補にそのエラーが残る場合は `PublishError` として扱い、確認後の差し替えへ進めない。

- [ ] **Step 3: 保存、非公開化、リネームを実装する**

保存はstatusを変更せず、publishedページの下書き保存も `published` のまま正本とlocalhost表示だけを更新する。非公開化はstatusをdraftへ変更してsiteを再生成する。リネームは名前付きページだけを受け付け、publishedなら旧URLredirect情報を候補へ追加し、draftなら追加しない。対象ページまたはリンク元に問題がある場合は処理を拒否する。

- [ ] **Step 4: 対象テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/authoring/test_service.py -q`

Expected: すべてPASS。公開失敗時の無作成、公開済み編集、`published_at` 維持、非公開placeholder、リネームの公開境界を確認する。

- [ ] **Step 5: コミットする**

```sh
git add src/log_migration/authoring/service.py tests/authoring/test_service.py
git commit -m "Add authoring state transitions"
```

## Task 6: Localhost WSGI app and split editor

**Files:**
- Create: `src/log_migration/authoring/web.py`
- Create: `src/log_migration/templates/authoring/layout.html`
- Create: `src/log_migration/templates/authoring/management.html`
- Create: `src/log_migration/templates/authoring/editor.html`
- Create: `src/log_migration/templates/authoring/local.html`
- Create: `src/log_migration/static/authoring/editor.js`
- Create: `src/log_migration/static/authoring/authoring.css`
- Create: `tests/authoring/test_web.py`

**Interfaces:**
- `create_app(service: AuthoringService) -> Callable` はWSGIアプリを返す。
- `GET /` は当日ページがあれば `/editor/<id>`、なければ未保存の当日編集画面へ遷移する。
- `GET /manage` はページ一覧、検索、statusフィルタ、空ページフィルタを表示する。
- `GET /editor/today` と `GET /editor/<page_id>` は分割編集画面を返す。
- `GET /<route>` は保存済みまたは空のlocalhost閲覧ページを返し、draft本文も表示できる。
- `POST /api/preview` は `{page_id, page_type, date, name, title, body}` を受け、`{"html": str, "errors": list[str]}` を返す。
- `POST /api/save`、`/api/publish`、`/api/unpublish`、`/api/rename` はサービスを呼び、成功時はページJSON、失敗時はHTTP 409または422と日本語エラーJSONを返す。

- [ ] **Step 1: WSGI APIの失敗テストを書く**

`wsgiref.util.setup_testing_defaults` と `io.BytesIO` を使うテストヘルパーで、外部プロセスなしにJSON APIと閲覧ルートを検証する。

```python
def test_save_creates_empty_wiki_target(tmp_path):
    app = create_app(service_for(tmp_path))
    response = request_json(app, "POST", "/api/save", {
        "page_type": "date", "date": "2026-01-01", "title": "", "body": "[[page-a]]",
    })
    assert response.status == 200
    assert response.json["status"] == "draft"
    assert request_json(app, "GET", "/page-a").status == 200


def test_preview_does_not_persist_unsaved_link_target(tmp_path):
    service = service_for(tmp_path)
    response = request_json(create_app(service), "POST", "/api/preview", {
        "title": "", "body": "[[page-a]]",
    })
    assert 'href="/page-a"' in response.json["html"]
    assert service.repository.find_route("/page-a") is None
```

- [ ] **Step 2: WSGIルーティングとテンプレートを実装する**

`web.py` は標準ライブラリでJSON body、URL path、query string、HTML responseを処理する。ユーザー由来の文字列は `html.escape` してテンプレートへ渡す。local閲覧ページでは `render_page(..., mode="local")` を使い、空ページに「まだ内容がありません」、逆リンクの見出しに「リンク元」を表示する。問題を空本文として隠さず管理画面へ表示する。

- [ ] **Step 3: 分割編集画面のJavaScriptとCSSを実装する**

`editor.html` は左にラベル付きタイトル入力とMarkdown textarea、右に `aria-live="polite"` のプレビュー領域を置く。`editor.js` は入力から300ms後に `/api/preview` を呼び、保存ボタンで `/api/save`、公開ボタンで `window.confirm("この内容を公開しますか？")` 後に `/api/publish` を呼ぶ。保存後は編集画面に留まり、保存日時とstatusを更新する。dirty状態だけ `beforeunload` で警告する。

`authoring.css` は編集領域を2列にし、狭い画面では入力欄を上、プレビューを下へ積む。ボタン、入力欄、リンクのキーボードフォーカスを表示する。管理画面ではページ種別、名前または日付、status、空状態を一覧で確認できる。

- [ ] **Step 4: 対象テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/authoring/test_web.py -q`

Expected: すべてPASS。保存、未保存プレビュー、local draft閲覧、public draft非表示、HTTPエラー、分割画面の必須要素を確認する。

- [ ] **Step 5: コミットする**

```sh
git add src/log_migration/authoring/web.py src/log_migration/templates/authoring src/log_migration/static/authoring tests/authoring/test_web.py
git commit -m "Add localhost authoring interface"
```

## Task 7: CLI startup and project documentation

**Files:**
- Create: `src/log_migration/authoring/cli.py`
- Create: `src/log_migration/authoring/__main__.py`
- Modify: `README.md`
- Create: `tests/authoring/test_cli.py`

**Interfaces:**
- `build_parser() -> argparse.ArgumentParser` は `--content`、`--index`、`--site`、`--host`、`--port` を持つ。
- `main(argv: Sequence[str] | None = None) -> int` はcontentとindexを作成して走査し、WSGI serverを起動する。
- 起動コマンドは `mise exec -- .venv/bin/python -m log_migration.authoring --content content --index data/index/authoring.sqlite3 --site site --host 127.0.0.1 --port 8000` とする。

- [ ] **Step 1: CLIの失敗テストを書く**

必須引数エラーとhost `127.0.0.1`、port `8000` の既定値を検証する。既存の `python -m log_migration` のparserテストも残す。

- [ ] **Step 2: CLIとモジュールエントリポイントを実装する**

`main()` はcontentディレクトリ、index親ディレクトリを作成し、`ContentRepository.refresh()`、`AuthoringDatabase.rebuild()`、`wsgiref.simple_server.make_server` の順に実行する。`KeyboardInterrupt` は正常終了とする。

- [ ] **Step 3: READMEへ起動と運用境界を追記する**

`.venv` 作成後の起動コマンド、localhost管理画面、`content/` が正本であること、`data/index/authoring.sqlite3` と `site/` が生成物であること、明示的な公開操作が必要であることを説明する。保存前はMarkdownを作らない点も明記する。

- [ ] **Step 4: 対象テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/authoring/test_cli.py tests/test_cli.py -q`

Expected: すべてPASS。

- [ ] **Step 5: コミットする**

```sh
git add src/log_migration/authoring/cli.py src/log_migration/authoring/__main__.py README.md tests/authoring/test_cli.py
git commit -m "Add authoring server command"
```

## Task 8: Integrated acceptance tests and verification

**Files:**
- Create: `tests/authoring/test_end_to_end.py`
- Modify: `README.md` only if the manual verification command differs from Task 7.

**Interfaces:**
- E2Eテストは `create_app()` と `AuthoringService` を同一プロセスで使い、ブラウザ依存のないHTTPレベルで完了条件を検証する。
- 手動確認ではTask 7のlocalhostサーバーを起動し、`http://127.0.0.1:8000/` をブラウザで開く。

- [ ] **Step 1: 設計書の受け入れ条件をE2Eテストで結ぶ**

当日ページの未保存起動、初回保存、同日重複、Wikiリンクによる空ページ、local/publicのタブ挙動、draft本文非公開、公開のステージング、空placeholder、リネームとredirect、壊れたfrontmatter、SQLite削除後の再構築を一つのテスト群で確認する。

```python
def test_authoring_flow_save_publish_rename_and_rebuild(tmp_path):
    service = service_for(tmp_path)
    app = create_app(service)
    saved = request_json(app, "POST", "/api/save", {
        "page_type": "date", "date": "2026-01-01", "title": "", "body": "[[page-a]]",
    })
    assert saved.json["status"] == "draft"
    service.publish(publish_request(saved.json["id"], body="[[page-a]]"))
    assert public_exists(tmp_path, "2026-01-01")
    service.rename(page_id_for(tmp_path, "page-a"), "page-b")
    assert "page-b" in read_source(tmp_path, "2026-01-01")
    (tmp_path / "data" / "index" / "authoring.sqlite3").unlink()
    service.database.rebuild(service.repository.refresh())
    assert service.database.search("page-b", None)
```

- [ ] **Step 2: 投稿機能の全テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest tests/authoring -q`

Expected: 投稿機能の全テストがPASS。

- [ ] **Step 3: 既存テストを実行する**

Run: `mise exec -- .venv/bin/python -m pytest -q`

Expected: 既存移行機能を含む全テストがPASS。既存の移行生成物とカードモードの挙動に変更がない。

- [ ] **Step 4: localhostで手動確認する**

Run: `mise exec -- .venv/bin/python -m log_migration.authoring --content content --index data/index/authoring.sqlite3 --site site --host 127.0.0.1 --port 8000`

ブラウザで、分割編集画面、`[[page-a]]` の新しいタブ遷移、保存後の状態表示、公開確認、公開後の同一タブ遷移、公開済みページの編集と再公開、管理画面の検索・statusフィルタ・空ページ・逆リンク・リネームを確認する。

- [ ] **Step 5: 最終差分を確認する**

Run: `git --no-pager diff --check main...HEAD`

Expected: 出力なし。`git status --short` で意図しない生成物や未追跡ファイルがないことを確認する。

- [ ] **Step 6: 最終コミットを作成する**

```sh
git add tests/authoring/test_end_to_end.py README.md
git commit -m "Verify authoring end to end"
```

## Plan self-review checklist

- [ ] 正本、SQLite再構築、外部編集エラー、既存移行データ読み取り専用をTask 1〜2で扱っている。
- [ ] 日付一意性、名前検証、URLエンコード、空ページ、Wikiリンク、逆リンク、リネームをTask 1〜2とTask 5で扱っている。
- [ ] Markdown拡張、生HTML禁止、コードハイライト、local/publicのリンクターゲットをTask 3で扱っている。
- [ ] draft本文非公開、空placeholder、公開逆リンク、公開失敗時の旧site保持、redirectをTask 4〜5で扱っている。
- [ ] 分割編集画面、保存後の滞留、未保存警告、管理画面、localhost閲覧をTask 6で扱っている。
- [ ] CLI、README、全受け入れ条件、既存テストとの非干渉をTask 7〜8で扱っている。
- [ ] 未実装の仮置き表現や曖昧な手順を計画本文へ残していない。
