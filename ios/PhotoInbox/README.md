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
open PhotoInbox.xcodeproj
```

Bundle IDは `com.asonas.weblog.PhotoInbox`、Apple Developer Teamは `QYP65434UW` です。
実機では初回起動後、weblog.ason.as の端末設定で発行した12文字のコードを、アプリ右上の「A」から入力します。

## テスト

```sh
mise run ios:lint
mise run ios:test
mise run ios:coverage
```

`ios:coverage` はテストを実行し、API client、認証状態、upload処理を含む
`PhotoInbox.app` のファイル別coverageを表示します。
