---
name: preview-in-worktree
description: Preview this repository's frontend from a linked worktree using the API server already running from main. Use when asked to start or check a worktree frontend preview.
---

# Preview in worktree

1. `git worktree list` で対象の作業worktreeとmainのパスを確認する。起動コマンドは対象worktreeを作業ディレクトリとして直接実行する。対象が不明なら特定してから進める。
2. `lsof` で `127.0.0.1:8000` の待受と、そのPIDのcwdがmainのworktreeであることを確認する。APIが止まっているか別のworktreeから起動していれば、その状態を伝える。プレビューのために別のAPIを起動しない。Viteの `AUTHORING_API_ORIGIN` は既定でこのアドレスを指す。
3. 作業worktreeに `node_modules` がなければ、mainにインストール済みで `package-lock.json` が一致するときだけmainの `node_modules` への一時的なシンボリックリンクを作る。それ以外は作業worktreeで `mise exec -- npm ci` を実行する。一時リンクを作ったか記録する。
4. 要求されたポートがなければ5174番以降から空きを選ぶ。`lsof -nP -iTCP:<port> -sTCP:LISTEN` で確認し、作業worktreeで `mise exec -- npm run dev -- --port <port> --strictPort` を起動する。占有によって起動に失敗したら、別の空きポートで再試行する。`mise run dev` はAPIも起動するので使わない。
5. Viteの起動ログに表示されたURLと選んだポートの待受を確認する。Web取得機能または `ax` でフロントエンドと、そのポートの `/api/pages` の応答を確認する。APIが利用できない場合は、フロントエンドだけ起動したことを明示する。URL、ポート、API接続の結果を報告し、プレビュー用プロセスは起動したままにする。

停止を依頼されたら、この手順で起動したフロントエンドだけを止め、待受が消えたことを確認する。作成した一時的な `node_modules` リンクは停止後に削除する。他のworktreeやmainのAPIプロセスには触れない。
