# Task 4 Report

## Summary

- `lib/weblog_authoring/publisher.rb` に `ReleaseManifest` と `StaticPublisher`
  を追加し、strict な release metadata load/serialize、public build plan、
  staging swap、publish result の返却を実装した。
- `templates/authoring/public.html` を追加し、既存
  `MarkdownRenderer#render_page(mode: "public")` の出力を包む最小 template
  を用意した。
- `test/authoring/test_publisher.rb` を追加し、Task 4 の focused tests を
  実装した。

## Implementation

### Release manifest

- `content/.authoring-release.json` 相当の payload を扱う
  `ReleaseManifest#load`, `#serialize`, `#normalize` を実装した。
- manifest root / page entry / redirect entry の key と型を厳格に検証し、
  malformed JSON や欠落 key は `PublishError` として止めるようにした。
- release snapshot 内の page は `published` / `published_at` 必須とし、
  named/date の整合、ID/route の重複も reject する。
- redirect は load/serialize 時点で chain flatten するが、flatten 前の
  中間 target が current published でないこと自体では reject しない。

### Public build plan

- public site に描画する page 集合と、成功後に保存すべき
  `release_candidate` を分離した。
- 既存 release snapshot に page がある場合、public build はその snapshot
  本文を使い、未公開の current source 編集を混ぜない。
- 初回公開の page は current source から public build と
  `release_candidate` の両方を作る。
- public page から参照された named page が未公開または空の場合だけ、
  本文なし placeholder を作る。draft-only 参照は public output に出さない。
- backlinks は public build に含まれる published page だけから計算する。
- redirect は `release_snapshot.redirects + snapshot.redirects` をまとめて
  flatten し、final target が今回の public output に存在するものだけを残す。
  cycle と `old_route` の collision は public output に対して reject する。

### Build / swap / publish

- `StaticPublisher#build` は `site.staging-*` 用ディレクトリへだけ書き込み、
  direct site 編集はしない。
- `#swap` は既存 site を `site.previous-*` へ退避してから rename し、
  failure 時は旧 site を restore する。
- `#publish` は swap 後に `PublishResult` を返し、service が後で
  manifest を原子的に保存できるように `release_candidate` と
  serialized manifest を返すだけにした。
- build/swap failure 時に partial staging を消し、旧 site を保持する。

## Verification

### Environment

- `git branch --show-current`
  - `weblog-authoring-design`
- `mise exec -- ruby --version`
  - `ruby 3.3.6`

### Syntax checks

- `mise exec -- ruby -c lib/weblog_authoring/publisher.rb`
- `mise exec -- ruby -c test/authoring/test_publisher.rb`

どちらも `Syntax OK`。

### Focused tests

- `mise exec -- ruby -Itest test/authoring/test_publisher.rb`

結果:

```text
10 runs, 50 assertions, 0 failures, 0 errors, 0 skips
```

確認できた項目:

- malformed release metadata rejection
- release snapshot body retention for already-published pages
- first publish uses current source and can emit placeholder pages
- draft-only references stay out of public output
- redirect chain flattening across release/current metadata
- redirect cycle and collision rejection
- public-source problem rejection and unrelated draft problem ignore
- swap failure keeps the old site in place

## Self-review

- `MarkdownRenderer` を再利用し、public HTML の再実装はしていない。
- redirect chain の flatten は class method に寄せ、instance 側では明示的な
  receiver で呼ぶよう整理した。
- `release_candidate` は current published source から作り、
  `published_at` だけ既存 release snapshot を優先するため、Task 5 の service
  から原子的保存へ接続しやすい形にしている。
- 変更は Task 4 で指定された 3 ファイルと report のみに限定した。
