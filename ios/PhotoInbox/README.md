# Photo Inbox for iOS

直近7日分の写真を選び、weblog.ason.as の写真インボックスへ送るiOSアプリです。

## 開発

XcodeプロジェクトはXcodeGenで生成します。

```sh
xcodegen generate
open PhotoInbox.xcodeproj
```

Bundle IDは `com.asonas.weblog.PhotoInbox`、Apple Developer Teamは `QYP65434UW` です。
実機では初回起動後、weblog.ason.as の端末設定で発行した12文字のコードを、アプリ右上の「A」から入力します。

## テスト

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project PhotoInbox.xcodeproj \
  -scheme PhotoInbox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO
```
