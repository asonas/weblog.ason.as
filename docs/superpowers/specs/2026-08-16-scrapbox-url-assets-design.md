# Scrapbox URLアセット移行 設計

## 背景

`/Users/asonas/Downloads/asonas-memo.json` を調査したところ、877ページの本文と日時は含まれているが、画像・音声・動画のバイナリを格納するフィールドは含まれていなかった。

一方で、本文中にはGyazoを中心に外部URLが含まれている。

- Gyazo URLはユニーク約340件
- 画像拡張子を持つURLはユニーク約78件
- 音声・動画拡張子を持つURLも存在する

現在の移行器はJSONの明示的な `assets` フィールドだけをアセットとして扱うため、実データではアセット数が0になり、外部URLをブラケット記法の内部リンクとして誤認している。

## 目的

1. Scrapbox内部リンクと外部URLを正しく分類する。
2. 外部URLを記事との関係を持つアセット候補として抽出する。
3. 元URL、種別、参照元、固定IDを決定的なmanifestへ保存する。
4. 通常の移行処理をネットワークから独立させる。
5. 明示的なコマンドでアセットを取得し、取得成否を記録できるようにする。

## 非目的

- 移行処理中に自動で外部サイトへアクセスすること
- OGP取得やOGP画像生成
- 外部サイトの内容を正本として保存すること
- URLの有効性を理由に本文からURLを削除すること
- リモートサービスへの自動再試行・定期同期

OGP表示と定期的な再取得は、URLアセットの抽出・取得が安定した後の別フェーズとする。

## 方針

### 1. URL分類

Scrapboxの角括弧記法を次の順で分類する。

- 角括弧内に `http://` または `https://` のURLが含まれる場合は外部URL。
- URLを含まず、ページタイトルの対応表に存在する場合は解決済み内部リンク。
- URLを含まず、対応表に存在しない場合は未解決内部リンク。

本文中の裸URLも外部URLとして抽出する。外部URLは本文の文字列を保持し、内部リンク用の `/posts/<id>/` へ書き換えない。

外部URLには次の種別を付ける。

- `image`: URLの拡張子または既知の画像ホストから画像と判断できるもの
- `audio`: 音声拡張子を持つもの
- `video`: 動画拡張子を持つもの
- `url`: 上記以外。OGP取得対象になり得る一般URL

種別は推測値であり、取得時の `Content-Type` を優先して更新する。

### 2. アセットIDとmanifest

同一URLは記事をまたいで同じアセットIDを共有する。

```text
asset_<sha256(canonical_url)[:16]>
```

canonical URLではスキームとホスト名を小文字化し、フラグメントを除去する。クエリ文字列は署名付きURL等の意味を壊さないため保持する。

正規化出力に `asset-manifest.json` を生成する。

```json
{
  "assets": [
    {
      "id": "asset_...",
      "url": "https://gyazo.com/...",
      "kind": "image",
      "source_post_ids": ["post_..."]
    }
  ]
}
```

manifestは入力と正規化結果だけから決定的に生成し、取得状態や実行時刻を持たせない。取得状態は別のレポートに保存する。

既存のローカル添付ファイル参照もmanifestの入力へ統合するが、元の相対パス情報は失わない。

### 3. アセット取得

通常の移行コマンドとは別に、manifestを入力にした明示的な取得コマンドを提供する。

```sh
mise exec -- bin/fetch-assets \
  --manifest data/normalized/asset-manifest.json \
  --output data/normalized/assets \
  --report data/reports/asset-fetch-report.json
```

取得コマンドの動作は次のとおりとする。

- `http` と `https` のURLだけを対象にする。
- リダイレクト後の応答を取得する。
- `Content-Type`、HTTPステータス、保存先、SHA-256を記録する。
- 取得失敗時はエラーを記録し、manifestと本文を変更しない。
- 同じ内容を再取得しても同じアセットIDを使う。
- 保存先はIDを基準に決め、URL由来のパスをそのままファイル名にしない。

取得コマンドのネットワーク利用は明示的な実行時だけに限定する。通常の移行、テスト、静的表示はネットワークへ接続しない。

## 変更対象

- `lib/weblog_migration/scrapbox.rb`: 外部URLを内部リンクから除外し、角括弧と裸URLを抽出する。
- `lib/weblog_migration/models.rb` / `normalize.rb`: 正規化記事に外部URL参照を保持し、manifestを生成する。
- `lib/weblog_migration/index.rb`: URLアセットと記事のエッジを派生インデックスへ保存する。
- `lib/weblog_migration/report.rb`: URLアセット候補、未解決内部リンク、取得前の欠落情報を区別する。
- `lib/weblog_migration/render.rb`: URLアセットをURLカードのフォールバックとして表示する。
- `lib/weblog_migration/assets.rb`: manifestから明示的にアセットを取得する。
- `lib/weblog_migration/cli.rb` と `bin/migrate`: manifest生成を通常移行へ接続する。

## エラーと安全性

- malformed URLは本文から削除せず、manifestの対象外または失敗項目としてレポートする。
- 外部URLの内容をMarkdownやHTMLとして解釈しない。
- 取得したファイルはContent-Typeと拡張子を検証し、パストラバーサルを許可しない。
- 大きすぎる応答は上限を設けて失敗として記録する。
- 取得処理の失敗で正規化済みMarkdownやSQLiteをロールバックしない。

## 検証

- URLを含む角括弧記法が未解決内部リンクとして数えられない。
- 裸URLと角括弧内URLが同じcanonical URLならmanifest上で重複しない。
- 同一URLを複数記事が参照した場合、manifestの `source_post_ids` に両方が入る。
- 元JSONを変更せずに通常移行を再実行できる。
- 実データで約340件のGyazo URLが抽出される。
- 取得不能URLがあっても、取得レポートに残り、本文とmanifestは維持される。
- 取得コマンドを実行しない通常移行はネットワークへ接続しない。
