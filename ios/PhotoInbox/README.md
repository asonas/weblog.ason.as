# Photo Inbox for iOS

直近7日分の写真を選び、weblog.ason.as の写真インボックスへ送るiOSアプリです。

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
