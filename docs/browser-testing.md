# ブラウザテスト

worktreeのルートで `mise run dev:doctor` を実行し、Node・Rubyと依存関係を確認します。
`node_modules`のディレクトリだけでは不十分で、Viteとtsxの実体が必要です。

## 変更から選ぶ

| 変更 | 既存の検証 |
| --- | --- |
| 本文入力・保存・再開 | `test/browser/draft_editor.mjs` |
| 記事一覧・状態表示 | `test/browser/draft_administration.mjs` |
| 端末一覧・QRペアリング | `test/browser/mobile_pairing.mjs` |
| カバー選択・プレビューの画像キャプション | `test/browser/draft_cover.mjs`、`draft_cover_pieces.mjs`、`draft_cover_recovery.mjs` |
| 通信断・再接続 | `test/browser/draft_offline.mjs` |

```sh
mise exec -- node test/browser/draft_cover_pieces.mjs
```

上記テストは `test/fixtures/drafts/server.rb` を起動し、一時ディレクトリのDBを使用します。
mainの開発DBや本番認証を使わず、APIを18082番、Viteを15182番で起動します。
同じポートを使うテストは直列で実行します。各スクリプトの `finally` がブラウザと子プロセスを終了します。
異常終了時は残ったPIDの起動元を確認してから停止してください。

Chromeがインストールされていることが必要です。sandboxでポートのbindやChrome起動を拒否された場合は、対象のテスト実行に必要な権限で再実行します。

## fixtureを使う

新しい検証は近い既存テストを入口にし、APIの応答形式を推測して一式mockする前にfixtureを確認します。
遅延・通信失敗などを再現する場合は、そのリクエスト境界だけをPlaywrightのrouteで置き換えます。
fixtureは既定でlegacy形式を使い、Pieceの検証は `ARTICLE_PIECES_ENABLED=true` を明示します。
新しいシナリオでは対象テストがどちらを設定しているか確認してください。

textlintの純粋な処理・型・フロントエンド検証は `package.json` と `mise.toml` のfocused taskを参照します。
日本語IMEの変換中入力や実機キーボードの表示は、ビルドや合成イベントだけでは確認できません。使用OS・入力方法と実際に確認した範囲を記録します。
