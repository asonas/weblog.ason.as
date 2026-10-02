# Photo Inbox for Android

今日を含む直近7日分の写真を選び、weblog.ason.as の写真インボックスへ送るAndroidアプリです。

「メモ」タブでは本文だけのメモを作成・編集できます。変更は端末へ自動保存し、接続中はInboxへ同期します。
メモに保存期限はありません。通信できないときも本文と再送情報を保持し、再接続・再起動後に同期します。
管理画面で日記へ取り込んだメモは一覧から消えます。端末の接続を解除された場合も、未送信の本文は保持します。

## 必要環境

- mise
- Android 8.0（API 26）以降の端末

Windowsにmiseがない場合は、WinGetでインストールしてPowerShellを開き直します。

```powershell
winget install --id jdx.mise --exact
```

次にリポジトリのルートで以下を実行します。Temurin JDK 17、Android
SDK Command-line Tools、SDK 36、Build Tools 36.0.0、Platform Toolsが
インストールされます。

```powershell
mise run setup:android
```

## 開発

macOS / Linuxでは、リポジトリのルートからmise管理のJDK・SDKで実行します。

```sh
mise run android:build:unix
mise run android:test:unix
```

これらのタスクは `sh gradlew` を使うため、ラッパーの実行属性には依存しません。

Windowsではリポジトリのルートから次のコマンドでビルドします。

```powershell
mise run android:build
```

生成したAPKは`android/PhotoInbox/app/build/outputs/apk/debug/app-debug.apk`に
あります。

Android Studioでこのディレクトリを開く場合も、Gradle JDKにはJDK 17を
指定してください。miseを使わずに直接ビルドする場合は次のコマンドを使えます。

```sh
./gradlew assembleDebug
```

Windowsでは`gradlew.bat assembleDebug`を実行します。

## テスト

```sh
./gradlew test lint
```

Windowsではリポジトリのルートから次を実行できます。

```powershell
mise run android:test
```

## 実機での利用

1. APKを端末へインストールし、写真へのアクセスを許可します。
2. weblog.ason.as の端末設定で12文字のペアリングコードを発行します。
3. アプリ右上の「設定」でコードを入力します。
4. 直近7日分の写真から送る写真を選び、「すべて送る」を押します。

送信処理はWorkManagerの永続キューで行われます。送信済み・待機・失敗の件数を表示し、失敗した写真は理由と問い合わせIDを確認して再送または送信対象から除外できます。通信障害・408・429・5xxは自動再試行し、それ以外の失敗は手動操作を待ちます。サイズ・SHA不正の再送では写真データを作り直します。同じMediaStore URIはキューへ重複登録されません。送信tokenはAndroid Keystoreで暗号化されます。

写真はJPEGまたは透過を保持したPNGに変換し、25MiB以下になるよう品質・解像度を調整します。変換後の幅・高さも送信します。

## 配布

配布方法はGoogle Play Consoleの内部テストとします。
`android/PhotoInbox/` または `.github/workflows/android-internal.yml` の変更を
mainへpushすると、GitHub Actionsが単体テスト、署名済みAABのビルド、内部テストへの配布を実行します。
Actionsの「Android internal testing」からmainを指定して手動実行することもできます。

Google Playの認証にはWorkload Identity Federationを使います。
`weblog-ason-as` の `github-actions` プールは、このリポジトリのmainブランチに限定されています。
配布先は `com.asonas.weblog.PhotoInbox` の内部テストトラックです。
GitHub Secretsの `ANDROID_KEYSTORE_BASE64` にPKCS12形式のアップロード鍵、
`ANDROID_KEYSTORE_PASSWORD` に鍵のパスワードを登録します。鍵のエイリアスは `upload` です。
`versionCode` はworkflowの実行番号と再実行番号から生成します。

手動配布する場合は、Android Studioの「Generate Signed App Bundle or APK」で
同じアップロード鍵を使い、既存リリースより大きい `versionCode` のAABを内部テストへ登録します。
内部テスターの実機で次を確認してから段階的に配布します。

1. ペアリング後に写真を送信できる。
2. Webの写真インボックスに同じ写真が1件だけ表示される。
3. 写真を記事へ挿入して保存できる。
4. 保存後、使用済み写真がWebのインボックスから除去される。
5. Androidアプリでは送信済みになり、再選択できない。
