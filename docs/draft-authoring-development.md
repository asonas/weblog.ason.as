# 記事編集の開発

## 現在の入口

`mise run dev` はmainのAPI・Vite・Bluesky OAuthサーバーを起動します。
APIは `AUTHORING_DRAFTS_ENABLED=1` で公開済みsnapshotを読み、編集中の内容は公開しません。
開発APIではかけらが既定で有効です。`ARTICLE_PIECES_ENABLED=false` を明示した場合だけ無効になります。
既存のlegacy記事は編集時の個別移行を使います。詳細は[Piece・Inboxの手順](runbooks/article-pieces-inbox.md)を参照してください。

実行中のAPIの機能は `/api/auth/session` の `draft_authoring` と `piece_authoring` で確認します。
レスポンスには認証情報も含まれるため、共有するログにはこの2項目だけを抽出してください。
起動設定の実装は `mise.toml` の `dev:api` と `lib/weblog_authoring/development_app.rb` です。

## 執筆中のリンク候補と過去の記述

開発APIは `envchain` の `weblog-authoring` 名前空間から `TYPESAFE_API_KEY` を受け取ります。初回のみ、自分のターミナルで登録します。

```sh
envchain --set --noecho weblog-authoring TYPESAFE_API_KEY
mise run dev
```

キーは開発APIとその子プロセスにだけ渡ります。Vite用の環境変数やリポジトリのファイルには保存しません。登録・変更後は開発APIを再起動してください。本番の秘密情報の登録や配布設定はこの変更には含まれません。

入力が7秒止まると、記事内の全かけらを認証・CSRF付き `POST /api/authoring/suggestions` へ順に送ります。変更のないかけらの結果は再利用し、フォーカスの移動だけでは再送しません。APIは公開記事を参照し、Jevへかけらの本文と候補記事の抜粋を送ります。キー未設定・オフライン・通信失敗でも本文編集と保存は続けられます。1かけらの上限は8,000文字で、超過したかけらを除いて確認します。

- リンク候補: 一文字や文章型のタイトルも含め、記事名との完全一致はコードで採用します。全角半角・大小文字・空白を正規化した一致、文字の近さ、記事本文に現れる語句から集めた表記揺れ候補は、Jevが同じ対象の名前・別名か判定します。各かけらで最大8件を表示し、同じかけら内でwikiリンク済みの記事は除外します。かけら番号・行・文字位置を添え、クリックすると該当かけらへ移動して `[[記事名]]` に置き換えます。元の表記を保持する別名付きwikiリンクは追加していません。
- 過去の記述: 公開記事のかけら、旧記事の段落を最大600文字で区切り、文字2-gramの一致で上位20件を取得します。Jevが同じ具体的な経験・結論、またはその変化・比較と判断し、現在のかけらから対応する記述を選べたものだけを最大3記事表示します。選択肢は現在の本文を文・改行と240文字の上限で区切り、候補との文字一致が多い上位12件です。「記述を比較」で現在の該当文と過去の記述を開けます。過去の記述の表示はアクティブなかけらを対象にし、そのかけら自身の公開済みコピーは除外します。埋め込み検索は使わないため、共通する語句がない言い換えは候補から漏れることがあります。
- 本文はクリック時にだけ変更します。候補を取得した本文・かけらと一致しない場合は適用せず、入力中やIME変換中の古い結果を破棄します。適用は独立したUndoで戻せます。

Jevは `jev-1.13.0` に固定しています。表記揺れのリンク候補は選択確率0.8以上、過去の記述は関連判定と対応箇所の選択がともに0.7以上を表示する初期設定で、ブログ全体で精度を校正した値ではありません。判定だけで本文は書き換えません。

実APIへの小さな評価は、合成した記事・入力だけで実行できます。キーや実記事の本文を出力しません。

```sh
envchain weblog-authoring mise exec ruby -- ruby -rbundler/setup scripts/check-writing-suggestions.rb
```

ルールとAPI認証の検証は `test/authoring/test_writing_suggestions.rb` と `test_lambda_api.rb`、クリック適用・Undo・古い応答・IME待機の検証は `test/browser/draft_suggestions.mjs` です。後者は隔離DBと候補APIの固定応答を使い、Jevの精度評価とは分けます。

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

## worktreeのmainへの取り込み

署名済みのコミットとcleanな両worktreeを準備し、mainのworktreeで実行します。`--`以降はrebase後に作業worktreeで実行する検証コマンドです。

```sh
mise exec -- node scripts/integrate-worktree.mjs <branch> -- mise run frontend:typecheck
```

専用AIキーでrebaseし、検証の成功・mainが動いていないこと・全対象コミットの署名キーを確認してからfast-forwardします。成功後だけworktreeとブランチを削除します。失敗時は作業worktreeを残します。pushは別操作です。

## 本番・実装履歴

本番の公開・下書き機構とPieceへの切替は2026-10-01に実施されています。
[運用入口](runbooks/pieces-production-release.md)から、稼働状態の確認と当時の記録を参照してください。
過去の実装段階・検証結果は[実装履歴](history/draft-authoring-implementation.md)に保存しています。
