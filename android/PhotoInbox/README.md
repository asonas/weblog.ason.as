# Photo Inbox for Android

今日の写真を選び、weblog.ason.as の写真インボックスへ送るAndroidアプリです。

## 必要環境

- Android StudioまたはJDK 17
- Android SDK 35
- Android 8.0（API 26）以降の端末

## 開発

Android Studioでこのディレクトリを開くか、次のコマンドでビルドします。

```sh
./gradlew assembleDebug
```

Windowsでは `gradlew.bat assembleDebug` を実行します。生成したAPKは
`app/build/outputs/apk/debug/app-debug.apk` にあります。

## テスト

```sh
./gradlew test lint
```

## 実機での利用

1. APKを端末へインストールし、写真へのアクセスを許可します。
2. weblog.ason.as の端末設定で12文字のペアリングコードを発行します。
3. アプリ右上の「設定」でコードを入力します。
4. 今日の写真から送る写真を選び、「すべて送る」を押します。

送信処理はWorkManagerの永続キューで行われます。通信に失敗した項目はネットワーク接続時に再送され、同じMediaStore URIはキューへ重複登録されません。送信tokenはAndroid Keystoreで暗号化されます。

## 配布

配布方法はGoogle Play Consoleの内部テストとします。Android Studioの
「Generate Signed App Bundle or APK」から署名済みAABを生成し、内部テストトラックへ登録します。内部テスターの実機で次を確認してから段階的に配布します。

1. ペアリング後に写真を送信できる。
2. Webの写真インボックスに同じ写真が1件だけ表示される。
3. 写真を記事へ挿入して保存できる。
4. 保存後、使用済み写真がWebのインボックスから除去される。
5. Androidアプリでは送信済みになり、再選択できない。
