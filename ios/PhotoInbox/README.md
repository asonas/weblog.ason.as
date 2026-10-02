# Photo Inbox for iOS

直近7日分の写真を選び、weblog.ason.as の写真インボックスへ送るiOS / iPadOSアプリです。
iOS 27およびiPadOS 27以降に対応しています。

「メモ」タブでは本文だけのメモを作成・編集できます。変更は端末へ自動保存し、接続中はInboxへ同期します。
メモに保存期限はありません。通信できないときも本文と再送情報を保持し、再接続・再起動後に同期します。
管理画面で日記へ取り込んだメモは一覧から消えます。接続を解除された場合は設定の「接続し直す」を使います。

## 開発

XcodeプロジェクトはXcodeGenで生成します。

```sh
mise run ios:generate
open ios/PhotoInbox/PhotoInbox.xcodeproj
```

Bundle IDは `com.asonas.weblog.PhotoInbox`、Apple Developer Teamは `QYP65434UW` です。
実機では初回起動後、weblog.ason.as の端末設定で発行した12文字のコードを、アプリ右上の「A」から入力します。

## テスト

署名なしのSimulator向けビルドは、リポジトリのルートで `mise run ios:build` を実行します。

```sh
mise run ios:lint
mise run ios:test
mise run ios:coverage
```

`ios:coverage` はテストを実行し、API client、認証状態、upload処理を含む
`PhotoInbox.app` のファイル別coverageを表示します。

## 配布

iOSはXcode CloudからTestFlightへ配布します。GitHub Actionsのworkflow一覧だけで配布の有無を判断しないでください。
Xcodeプロジェクトの生成は [ci_post_clone.sh](ci_scripts/ci_post_clone.sh) が行います。
トリガーのブランチ・パス条件とTestFlightの配布グループはリポジトリ外のXcode Cloud設定です。

設定と実行結果は [App Store ConnectのPhotoInbox](https://appstoreconnect.apple.com/apps/6805918942) のXcode Cloudで、`Default` workflowの開始条件・アクション・配布先を確認します。
2026-10-03に、mainへpushした `10e9bf03507a67de75be97f911ab0ef17f6cc237` に対する `PhotoInbox | Default | Archive - iOS` の成功をGitHub check runsで確認しました。
全ブランチ・全パスのトリガー条件やTestFlightグループの現在値は、この実行結果だけでは確定しません。

対象SHAのチェックは次のコマンドで確認できます。

```sh
gh api "repos/asonas/weblog.ason.as/commits/$(git rev-parse HEAD)/check-runs" \
  --jq '.check_runs[] | select(.app.slug == "xcode-cloud") | {name,status,conclusion,details_url}'
```

`details_url`でビルドの対象SHAとArchive結果を確認し、TestFlightで処理完了・配布グループ・ビルド番号を照合します。
Archive成功だけでテスターへの配布完了とは扱いません。端末では新しいビルドへ更新して確認してください。
