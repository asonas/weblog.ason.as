# Weblog Authoring Ruby Rewrite Plan

> **For agentic workers:** この計画は `weblog.ason.as` の投稿サーバーを書き換えるためのものです。Taskごとに実装、対象テスト、差分レビューを完了してから次へ進みます。

**Goal:** 開発マシンのlocalhostでMarkdown記事を書き、Wikiリンクと逆リンクを自動構築し、明示的な操作で安全に静的公開できる投稿インターフェースをRubyで実装する。

**Architecture:** Scrapbox移行・静的生成・アセット取得・投稿編集のすべてをRubyで実装する。`content/` のMarkdownとfrontmatterを正本とし、`data/index/authoring.sqlite3` は走査結果から再生成する派生インデックスとする。localhostの管理画面はRackアプリとして実装し、WEBrickでloopbackにbindする。公開操作では現在の正本を検証し、最後に公開したページのスナップショットと合わせた候補をステージング生成してから `site/` を差し替える。

**Tech Stack:** Ruby 4系（miseで選択）、Rack 3、rackup、WEBrick、sqlite3、Kramdownとkramdown-parser-gfm、Rouge、Psych、標準ライブラリのMinitest、プレーンHTML/CSS/JavaScript。フロントエンドのビルド環境やRuby Webフレームワークは追加しない。

**Spec:** `docs/superpowers/specs/2026-08-20-weblog-authoring-design.md`

## Global Constraints

- 投稿サーバー、投稿ドメイン、Scrapbox移行、Markdown描画、SQLiteインデックス、公開生成、localhost UI、CLIはRubyで実装する。別言語のサーバーは作らない。
- 移行・投稿・静的生成の実装、テンプレート、テストはRubyの依存と実行経路だけで構成する。
- 初期実装は `127.0.0.1` または `::1` にだけbindし、LAN公開、認証、AWS、S3、CloudFront、Lambda、外部公開APIは実装しない。
- `content/` のMarkdownとfrontmatterを正本とし、既存の `data/normalized/` は読み取り専用にする。SQLiteと `site/` は正本ではない。
- 日付ページはAsia/Tokyoの日付ごとに一つだけ作成し、URLとファイル名を `/yyyy-mm-dd` と `content/yyyy-mm-dd.md` に固定する。
- 名前付きページは大文字・小文字を区別し、名前を表示タイトルとURLの元にする。`[[page-a]]` は `/page-a` になり、空ページも有効なページとして扱う。
- Wikiリンク、通常のMarkdown、表、タスクリスト、取り消し線、言語指定付きコードブロックを扱う。生HTML、画像、添付、コード実行は扱わない。
- 編集画面はMarkdown入力欄とライブプレビューの分割表示だけを提供し、記事単体の管理用プレビュー画面は作らない。localhostの閲覧ページはリンク先として提供する。
- localhostのWikiリンクは新しいタブ、公開サイトのWikiリンクは同じタブで開く。
- 保存はdraftから始め、公開は明示操作と静的生成の成功を条件にする。削除機能は作らない。
- 公開済みページを編集して保存しても、最後に公開した内容を公開スナップショットとして保持する。次の公開が失敗した場合や、無関係なページを公開した場合に、未公開の編集内容がsiteへ混入してはならない。
- 公開生成はステージング後の原子的な差し替えとし、失敗時は以前の公開出力を保持する。公開済みリネームの旧URLredirectと公開スナップショットは再起動後も保持する。
- 外部編集で壊れたfrontmatter、Markdown、redirectまたはrelease metadataは自動修正・上書きせず、管理画面に表示して状態変更を拒否する。SQLiteの欠落・破損だけは正本から安全に再構築する。
- MarkdownとJSONのmutation APIはJSONのContent-Typeを要求し、loopback以外のHost、Origin、危険なrouteを受け付けない。ブラウザからのリンク表示に未保存の仮ページを使う場合も、ファイルやDBを作成しない。
- Ruby実行前に `command -v ruby` と `ruby --version` を確認し、実行は `mise exec --` または `bundle exec` 経由にする。
- コミットメッセージは英語で、Conventional Commits形式を使わず、先頭を大文字にする。

## File and module map

Rubyの投稿機能は移行機能を含む `lib/weblog_migration/` とは別の `lib/weblog_authoring/` に置く。

- `Gemfile`、`.ruby-version`: Ruby 4系と依存gemを固定する。
- `lib/weblog_authoring/models.rb`: ページ、文書、リンク、問題、保存・公開リクエストの値オブジェクト。
- `lib/weblog_authoring/names.rb`: ページ名の検証、日付判定、URL・ファイルパス変換。
- `lib/weblog_authoring/frontmatter.rb`: Psychを使ったstrictなfrontmatterの読み書き。
- `lib/weblog_authoring/links.rb`: Wikiリンクの抽出、本文置換、リネーム時のリンク更新。
- `lib/weblog_authoring/repository.rb`: `content/` の走査、正本ファイルの保存、原子的なファイル変更。
- `lib/weblog_authoring/database.rb`: 投稿用SQLiteスキーマ、integrity check、再構築、検索、逆リンク。
- `lib/weblog_authoring/markdown.rb`: Kramdownの安全なMarkdown描画、Wikiリンク、Rougeハイライト。
- `lib/weblog_authoring/publisher.rb`: 公開候補、空placeholder、redirect、公開siteのステージングと差し替え。
- `lib/weblog_authoring/service.rb`: 保存、公開、非公開化、リネーム、release metadataの調整。
- `lib/weblog_authoring/web.rb`: Rackアプリ、管理画面、分割編集画面、localhost閲覧、JSON API。
- `lib/weblog_authoring/app.rb`、`bin/authoring`: 設定、起動、loopback検証。
- `templates/authoring/`、`static/authoring/`: Rubyで配信するHTML、CSS、JavaScript。
- `test/test_helper.rb`、`test/authoring/`: Minitestのfixture、unit/API/publisher/E2Eテスト。
- `README.md`: Ruby版の起動方法と移行・静的生成コマンドを説明する。

`content/.authoring-redirects.json` は名前付きページの旧routeを保持する。`content/.authoring-release.json` は最後に公開したページの内部ID、route、タイトル、本文、リンク、公開メタデータを保持する。どちらも正本Markdownとは別の投稿管理メタデータであり、壊れていた場合は公開と状態変更を停止する。release snapshotは、保存済みだが未公開の現行Markdownで上書きしない。

## Task 1: Ruby runtime and document primitives

**Files:**

- Create: `.ruby-version`
- Create: `Gemfile`
- Create: `lib/weblog_authoring.rb`
- Create: `lib/weblog_authoring/models.rb`
- Create: `lib/weblog_authoring/names.rb`
- Create: `lib/weblog_authoring/frontmatter.rb`
- Create: `lib/weblog_authoring/links.rb`
- Create: `test/test_helper.rb`
- Create: `test/authoring/test_names.rb`
- Create: `test/authoring/test_frontmatter.rb`
- Create: `test/authoring/test_links.rb`

**Interfaces:**

- `PageDocument`, `PageProblem`, `WikiLink`, `Redirect`, `ReleaseSnapshot`, `SaveRequest`, `PublishRequest`をRubyの値オブジェクトとして定義する。
- `validate_page_name(name)`, `encoded_page_name(name)`, `page_path(content_dir, page_type, name:, page_date:)`を提供する。
- `parse_document(path, text)`, `serialize_document(document)`を提供する。
- `extract_wiki_links(body)`, `replace_wiki_links(body, old_name:, new_name:)`を提供する。

- [ ] `Gemfile`へRack、rackup、WEBrick、sqlite3、Kramdown、kramdown-parser-gfm、Rougeを追加し、Ruby 3.3.6でbundle installできることを確認する。
- [ ] ページ名の空白、Unicode、大文字・小文字、`/`、`?`、`#`、制御文字、date-shaped name、`manage`や`api`などの予約routeをテストする。
- [ ] frontmatterの必須キー、ID・日時・statusの型、未知キー、壊れたYAML、日付型の誤受理をテストする。Psychのsafe loadで任意クラスを生成しない。
- [ ] Wikiリンクのtrim、完全一致置換、長いコードフェンス内の無視、未保存リンク名の抽出をテストする。
- [ ] `bundle exec ruby -Itest test/authoring/test_names.rb` など対象テストを実行する。
- [ ] `Add Ruby authoring primitives`としてコミットする。

## Task 2: Content repository and rebuildable SQLite index

**Files:**

- Create: `lib/weblog_authoring/repository.rb`
- Create: `lib/weblog_authoring/database.rb`
- Create: `test/authoring/test_repository.rb`
- Create: `test/authoring/test_database.rb`

**Interfaces:**

- `ContentRepository#refresh`, `#get_page`, `#find_route`, `#list_pages`, `#save_draft`, `#rename_named_page`を提供する。
- `RepositorySnapshot`は有効なpages、problems、redirectsを持つ。壊れた文書を有効ページに混ぜない。
- `AuthoringDatabase#rebuild`, `#backlinks`, `#search`, `#integrity_ok?`を提供する。

- [ ] `content/*.md`を走査し、同日二重保存、名前衝突、`[[page-a]]`からの空draft生成、未知route、外部編集エラーを検証する。
- [ ] pages、links、problemsをSQLiteへ保存し、本文はSQLiteへコピーしない。保存後にMarkdownを変更した場合もrefreshがMarkdownを正とする。
- [ ] SQLiteが存在しない場合は作成し、integrity checkやschema migrationに失敗した場合は派生DBを`.corrupt-*`へ退避してからMarkdownから再構築する。正本ファイルを削除・修正しない。
- [ ] ファイル保存とリネームは一時ファイル、fsync、`File.rename`を使い、失敗時に作成・変更したファイルを元へ戻す。リネームでは対象自身のfrontmatter、リンク元本文、パスを一つのトランザクションで更新する。
- [ ] 保存されたページが参照する未存在名を空draftとして作成し、未保存のプレビューだけではMarkdownやSQLiteを作らない。
- [ ] SQLite削除・破損後の再構築、逆リンク、検索、リネーム衝突の対象テストを実行する。
- [ ] `Add Ruby content repository and index`としてコミットする。

## Task 3: Safe Markdown rendering

**Files:**

- Create: `lib/weblog_authoring/markdown.rb`
- Create: `test/authoring/test_markdown.rb`

**Interfaces:**

- `MarkdownRenderer#render(body, mode:)`はHTML、リンク、問題を返す。
- `MarkdownRenderer#render_page(page, backlinks:, mode:)`はlocalまたはpublicのページHTMLを返す。

- [ ] Kramdown GFMで表、タスクリスト、取り消し線、フェンスコードを描画し、Rougeで既知言語をハイライトする。未知言語と不正なコードブロックはエスケープ済みコードへフォールバックする。
- [ ] 生HTMLを無効化し、`javascript:`、外部画像、相対画像、添付リンクをHTMLとして通さない。画像記法は安全なエラーまたはテキストとして扱う。
- [ ] `[[page-a]]`をMarkdown parserへ渡す前に安全な内部URLへ変換し、localだけ`target="_blank"`と適切な`rel`を付与する。属性値は常にHTML escapeする。
- [ ] publicでは同一タブの通常リンク、localでは下書き・空ページ・未保存の仮ページへのリンクを表示する。外部入力から任意のrouteを生成しない。
- [ ] 表、task list、strike、script、画像、リンク属性、local/publicのtargetを対象テストで確認する。
- [ ] `Add Ruby authoring markdown renderer`としてコミットする。

## Task 4: Atomic static publisher and release snapshots

**Files:**

- Create: `lib/weblog_authoring/publisher.rb`
- Create: `templates/authoring/public.html`
- Create: `test/authoring/test_publisher.rb`

**Interfaces:**

- `StaticPublisher#build(snapshot, destination, release_snapshot:)`、`#swap(destination)`、`#publish(snapshot, release_snapshot:)`を提供する。
- `ReleaseManifest#load`、`#serialize`で最後に公開したページの内容と公開済みmetadataを永続化する。

- [ ] 公開済み本文だけを出力し、draft本文をsiteへ出さない。公開ページから参照された空または非公開ページは、ページ名、空状態、公開逆リンクだけのplaceholderとして生成する。
- [ ] 公開siteの各ページは公開snapshotから描画する。現行Markdownのstatusがpublishedでも、未公開の編集内容をrelease snapshotへ混ぜない。初回公開では候補を新しいsnapshotにし、成功後だけrelease metadataを更新する。
- [ ] 公開対象の壊れた文書、release metadataの欠落・不整合、redirectのcycle・collisionを検出して停止する。無関係なdraftの問題だけは公開対象外として管理画面へ残す。
- [ ] `site/<encoded-route>/index.html`を生成し、`site/`を直接変更せず`site.staging-*`から差し替える。buildまたはswap失敗時に旧site marker、旧release metadata、旧redirectを保持する。
- [ ] redirectをA→B→Cの連鎖でもA→Cへflattenし、リネーム後も旧routeを失わない。公開済みページの名前変更では旧routeにredirectを生成し、draftだけのリネームでは生成しない。
- [ ] draftの非公開、空placeholder、公開逆リンク、公開snapshotの保持、公開失敗時の旧site保持、redirect chain、release metadata破損を対象テストで確認する。
- [ ] `Add Ruby atomic static publisher`としてコミットする。

## Task 5: Authoring service and state transitions

**Files:**

- Create: `lib/weblog_authoring/service.rb`
- Create: `test/authoring/test_service.rb`

**Interfaces:**

- `AuthoringService#save_draft`, `#preview`, `#publish`, `#unpublish`, `#rename`を提供する。
- 保存と公開の候補は同一のdomain modelで扱い、ID、created_at、初回published_at、routeの不変性を明示する。

- [ ] 新規保存はdraftとし、入力本文とfrontmatterを保存してもsiteを更新しない。公開失敗時は新規Markdown、DB、site、release metadataを残さない。
- [ ] 公開済みページを編集保存したとき、現行Markdownは更新するが公開siteは最後のrelease snapshotを表示する。再公開成功後だけ新しい本文へ切り替える。
- [ ] 初回公開時だけpublished_atを設定し、再公開では最初のpublished_atを保持する。非公開化はsource、ID、リンクを維持し、公開siteから本文を除いてplaceholder規則を適用する。
- [ ] 名前付きページのリネームでは対象page IDを維持し、すべての正本Wikiリンクとrelease snapshot内のself-linkを更新する。衝突時はファイル、DB、metadataを変更しない。
- [ ] save/publish/unpublish/renameの途中で例外を起こすテストを用意し、各ファイルと旧siteのrollbackを確認する。dirty状態のまま非公開化・公開を許可しない。
- [ ] `Add Ruby authoring service`としてコミットする。

## Task 6: Rack authoring UI and localhost page views

**Files:**

- Create: `lib/weblog_authoring/web.rb`
- Create: `lib/weblog_authoring/app.rb`
- Create: `templates/authoring/manage.html`
- Create: `templates/authoring/editor.html`
- Create: `templates/authoring/page.html`
- Create: `static/authoring/app.css`
- Create: `static/authoring/app.js`
- Create: `test/authoring/test_web.rb`

- [ ] `/manage`は今日の日付ページまたは未保存の今日の編集画面を開き、Markdown textareaとライブpreviewを左右に表示する。記事単体の管理用preview画面は追加しない。
- [ ] 管理画面に新規日付ページ、名前付きページ、保存、公開、非公開化、リネームの明示操作を用意する。本文の自動保存は行わず、dirty状態の公開・非公開を拒否する。
- [ ] `POST /api/preview`は未保存本文をメモリ内だけで描画し、仮のリンク先ページを`GET`したときは空placeholderを返す。preview用のページをファイル・DBへ永続化しない。
- [ ] `POST /api/save`、`/publish`、`/unpublish`、`/rename`は`Content-Type: application/json`とloopbackのrequest originを検証し、エラーを入力項目へ関連付けたJSONで返す。成功時は同じ編集画面へ戻す。
- [ ] `/<route>`のpercent decoding、Unicode、二重decode、`.`、`..`、encoded slash、route collisionを検証する。`manage`、`api`、静的assetのnamespaceは名前付きページから予約する。
- [ ] localhost閲覧ページのWikiリンクは新しいタブ、publicテンプレートは同じタブとし、draft・empty・backlinksの可視範囲を分ける。
- [ ] HTML escape、属性escape、CSRF境界、loopback bind、キーボード操作、focus、狭幅のtextarea/preview overflow、preview応答の競合抑制を対象テストで確認する。
- [ ] `Add Ruby authoring web interface`としてコミットする。

## Task 7: CLI, README, and runtime consolidation

**Files:**

- Create: `bin/authoring`
- Create: `config.ru`
- Modify: `README.md`
- Keep: `lib/weblog_migration/` for Scrapbox移行・静的生成・アセット取得。
- Keep: `test/migration/` for移行処理とネットワーク境界の受入れテスト。

- [ ] `bin/authoring`は既定で`127.0.0.1:8000`にbindし、`--host`でloopback以外を指定した場合は起動前に拒否する。設定されるcontent/index/siteはrepository rootから解決し、任意の外部パスで正本を上書きしない。
- [ ] `config.ru`から同じRack appを起動できることを確認する。サーバー起動経路に別言語の呼び出しを残さない。
- [ ] READMEの投稿画面、Scrapbox移行、静的生成、アセット取得、URLカード取得のRubyコマンドを記載し、Ruby 4系とlocalhost限定を明記する。
- [ ] Ruby版のunit/API/E2E/移行受入れが通った後、リポジトリ全体に旧実装・依存・実行参照が残っていないことを確認する。
- [ ] `Switch authoring runtime to Ruby`としてコミットする。

## Task 8: End-to-end verification and final review

**Files:**

- Create or modify: `test/authoring/test_e2e.rb`
- Modify: `docs/superpowers/specs/2026-08-20-weblog-authoring-design.md` only if Ruby implementation details need to be recorded without changing agreed behavior.

- [ ] 一時repositoryで今日のページを保存し、同日二件目を拒否する。
- [ ] `[[page-a]]`から空ページを作成し、`2026-01-01`と`page-b`からのリンク元をlocalhostで表示する。未保存の仮リンク先も404にせず表示し、保存前に正本を作らない。
- [ ] draft、published、unpublished、公開済みページの未公開編集を確認し、publicにはrelease snapshotだけが出ることを確認する。
- [ ] 失敗するMarkdown、壊れたfrontmatter、redirect/release metadata、SQLite削除・破損をそれぞれ確認する。公開失敗時に旧siteが変わらないことを確認する。
- [ ] 名前付きページのrenameで本文中リンク、self-link、旧URLredirect、A→B→Cのchainを確認する。衝突時に全対象が不変であることを確認する。
- [ ] Rubyテスト、移行テスト、静的検査を実行する。Rubyサーバーはloopbackで起動し、HTTP smoke testを実際のRack/WEBrickへ送る。
- [ ] セキュリティ、アクセシビリティ、レイアウトの差分レビューを行い、未解決の重要指摘がないことを確認する。
- [ ] 最終的なIssueコメントにRuby採用、実装範囲、検証コマンド、残課題を記録する。Issueは検証完了まで`in_progress`のままにし、完了条件を満たした時点でだけ`done`へ進める。
