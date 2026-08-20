# Task 3 Report

## Summary

- `lib/weblog_authoring/markdown.rb` に `WeblogAuthoring::MarkdownRenderer` と `RenderedMarkdown` を追加した。
- `test/authoring/test_markdown.rb` を追加し、Task 3 の受け入れ条件に対応する focused test を実装した。

## Implementation

### Safe Markdown pipeline

- `[[page-a]]` は Kramdown に渡す前に内部センチネル URL へ変換し、render 時に安全な内部リンクへ戻すようにした。
- 既存の `extract_wiki_links` と `validate_page_name` を再利用し、Wiki-link の構文解析やページ名検証を重複実装していない。
- `mode: "local"` では保存済みページは `PageDocument#route` へ、未保存リンク先は一時 route へ解決し、`target="_blank"` と `rel="noopener noreferrer"` を付ける。
- `mode: "public"` では保存済みページだけ通常リンクにし、未保存リンク先は plain text へ落として問題として記録する。

### HTML safety

- Kramdown GFM を使いつつ、custom HTML converter で raw HTML を許可しないようにした。
- ただし GFM が内部生成する `del` と task-list 用 `input[type=checkbox]` だけは限定的に通し、それ以外の HTML 要素は要素全体を escape する。
- 画像記法は `<img>` を出力せず、`[image omitted: alt]` のテキストへ変換して problem を追加する。
- `javascript:` と相対パスの添付リンクはリンクとして出力せず、本文だけ残して problem を追加する。
- 通常の外部リンクは `http:`, `https:`, `mailto:` のみ許可した。

### Code blocks

- fenced code block は Rouge で既知言語だけ highlight する。
- 未知言語や Rouge 失敗時は、escape 済みの `<pre><code>` にフォールバックして problem を追加する。
- inline code は highlight せず、単純に escape した `<code>` を返す。

### Page rendering

- `render_page(page, backlinks:, mode:)` は本文、空ページメッセージ、problem list、backlinks list を含む framework-free HTML を返す。
- backlinks は `mode` に応じて local/public のリンク属性差分を持つ。

## Verification

### Dependency/runtime checks

- `git branch --show-current`
  - `weblog-authoring-design`
- `mise exec -- ruby --version`
  - `ruby 3.3.6`
- `mise exec -- bundle install`
  - Kramdown / kramdown-parser-gfm / Rouge を含む依存展開に成功

### Syntax checks

- `mise exec -- ruby -c lib/weblog_authoring/markdown.rb`
- `mise exec -- ruby -c test/authoring/test_markdown.rb`

どちらも `Syntax OK`。

### Focused tests

- `mise exec -- ruby -Itest test/authoring/test_markdown.rb`

結果:

```text
6 runs, 67 assertions, 0 failures, 0 errors, 0 skips
```

備考:

- `mise exec -- bundle exec ruby -Itest test/authoring/test_markdown.rb` は、この Ruby 3.3.6 環境で `minitest/autorun` を Bundler 管理下に見つけられず失敗した。
- `mise exec -- ruby -Itest ...` では `minitest-5.20.0` を正しく読めたため、focused test はこの経路で確認した。

## Self-review

- 変更対象は Task 3 で指定された `markdown.rb` と `test_markdown.rb` に限定した。
- 既存の Python authoring 実装や他タスクの Ruby ファイルは変更していない。
- `lib/weblog_authoring.rb` には require を追加していない。Task 3 の範囲を超えないためで、将来 task 側で集約 require が必要なら別途対応する。

Parent commit: `2e78547 Add Ruby authoring markdown renderer`.

## Fix Round 1: Attribute whitelist hardening

### Finding addressed

- Kramdown の inline attribute list が paragraph、table、code block などの `attr`
  に入り、converter の通常描画経路から `onclick` のような属性がそのまま
  HTML へ出る問題を修正した。
- ordinary Markdown の外部 anchor は設計どおり維持し、`http:`, `https:`,
  `mailto:` の `href` は許可したまま、許可属性だけを通すようにした。

### Implementation changes

- custom converter に tag-aware な属性 whitelist を追加した。
- `format_as_span_html`, `format_as_block_html`,
  `format_as_indented_block_html`, `convert_li`, `convert_hr`,
  `convert_html_element`, custom code block rendering の全経路を
  sanitizer 経由にそろえた。
- 許可しない属性名、または許可されない値は HTML へ出力せず、
  `attribute omitted from <tag>: attr` を warning として返すようにした。
- 保持する属性は Task 3 の要件に合わせ、`class`, `id`,
  table alignment の `style`, task-list checkbox の固定属性、
  safe internal/external `href`, local `target="_blank"` と
  `rel="noopener noreferrer"` に限定した。

### Regression coverage

- paragraph への block IAL 注入
- external anchor への safe `title` と unsafe `onclick` の混在
- table への block IAL 注入
- fenced code block への IAL 注入

### Verification commands

- `git branch --show-current`
  - `weblog-authoring-design`
- `mise exec -- ruby -c lib/weblog_authoring/markdown.rb`
  - `Syntax OK`
- `mise exec -- ruby -c test/authoring/test_markdown.rb`
  - `Syntax OK`
- `mise exec -- ruby -Itest test/authoring/test_markdown.rb`

結果:

```text
7 runs, 87 assertions, 0 failures, 0 errors, 0 skips
```

### Self-review

- 変更は Task 3 の `markdown.rb`, `test_markdown.rb`, `task-3-report.md`
  のみに限定した。
- ordinary Markdown の safe external anchor は維持しつつ、unsafe/unknown
  attribute 名は warning を返して落とすことを focused test で確認した。
