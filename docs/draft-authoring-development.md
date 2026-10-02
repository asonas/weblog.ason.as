# 記事編集の開発

## 現在の入口

`mise run dev` はmainのAPI・Vite・Bluesky OAuthサーバーを起動します。
APIは `AUTHORING_DRAFTS_ENABLED=1` で公開済みsnapshotを読み、編集中の内容は公開しません。
開発APIではかけらが既定で有効です。`ARTICLE_PIECES_ENABLED=false` を明示した場合だけ無効になります。
既存のlegacy記事は編集時の個別移行を使います。詳細は[Piece・Inboxの手順](runbooks/article-pieces-inbox.md)を参照してください。

実行中のAPIの機能は `/api/auth/session` の `draft_authoring` と `piece_authoring` で確認します。
レスポンスには認証情報も含まれるため、共有するログにはこの2項目だけを抽出してください。
起動設定の実装は `mise.toml` の `dev:api` と `lib/weblog_authoring/development_app.rb` です。

## worktreeでのプレビュー

1. worktreeのルートで `mise run dev:doctor` を実行する。
2. [preview-in-worktree](../.agents/skills/preview-in-worktree/SKILL.md)に従って、mainの8000番APIへ接続するViteだけを別ポートで起動する。

doctorは依存関係とポートの起動元を確認する読み取り専用タスクです。パッケージのインストール、API起動、DB更新は行いません。
ブラウザテストはプレビューとは別の隔離APIを使用します。[テスト案内](browser-testing.md)を参照してください。

## 既存の開発DBを切り替える場合だけ

旧DBを使う開発環境を公開snapshotの読み取りへ切り替える場合は、APIを停止して次を実行します。

```sh
mise exec -- ruby scripts/prepare-development-draft-reader.rb
mise exec -- ruby scripts/prepare-development-draft-reader.rb --apply
```

この処理は既存の公開記事の移行結果を検証し、両DBを退避して再インポートによる上書きを防ぎます。
本文の再インポートや、日記のかけら変換は行いません。移行済みの環境で日常的に実行する手順ではありません。

## 本番・実装履歴

本番の公開・下書き機構とPieceへの切替は2026-10-01に実施されています。
[運用入口](runbooks/pieces-production-release.md)から、稼働状態の確認と当時の記録を参照してください。
過去の実装段階・検証結果は[実装履歴](history/draft-authoring-implementation.md)に保存しています。
