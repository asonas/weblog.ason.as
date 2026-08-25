# Raindropのブックマーク取得契約

調査日: 2026-08-25

## 結論

個人専用の取り込みには、RaindropのApp Management Consoleで発行したTest tokenをサーバー側のsecretとして保存し、REST API v1をBearer認証で読む構成が最小である。ブックマークの識別子にはURLではなくRaindropの`_id`を使い、表示とエディタ挿入にはAPIが返す`link`をそのまま使う。

初回取得は`GET https://api.raindrop.io/rest/v1/raindrops/0?sort=-created&perpage=50&page=N`で行う。`0`はTrashを除く全コレクション、`page`は0始まり、`perpage`は最大50件である。インボックスの意味上の日時には`created`を使う。

継続取得は完全なchange feedではない。更新候補を`search=lastUpdate:>...`で重複を含めて再取得し、`_id`でupsertする。ページ走査中にも一覧が変わり得るため、前回境界と同値の時刻を含む安全な重複窓を取り、既知IDを再処理できるようにする。削除は別途Trash（collection ID `-99`）を照合する。ただしTrashを空にした後の永久削除には公開API上のtombstoneがないため、厳密な削除追跡が必要なら定期的な全件照合が必要になる。

## 確認した契約

### 認証

- API呼び出しは`Authorization: Bearer <access_token>`を使う。
- 自分のアカウントだけを扱う用途では、公式資料がApp Management ConsoleのTest tokenを案内している。
- 通常のOAuth 2アクセストークンは2週間で期限切れになり、refresh tokenによる更新が必要である。Test tokenはこの期限切れの例外と明記されている。
- OAuth利用時のレート上限は、認証ユーザーごとに毎分120リクエスト。残量とresetはレスポンスヘッダーで確認できる。

したがって単一ユーザーの第一段階ではTest tokenで十分である。将来の複数ユーザー対応は今回の地図の対象外であり、OAuth認可画面やrefresh token保管を先に実装する必要はない。

### ページングと取得範囲

- `GET /rest/v1/raindrops/{collectionId}`の`collectionId=0`はTrash以外の全ブックマークを返す。
- `page`は0始まりのページ番号、`perpage`は最大50件。
- 既定順は`-created`で、`created`の昇順も指定できる。
- APIのページングはcursorではない。公式資料には読み取りスナップショットの保証も記載されていない。

ページ間で追加・更新が起きるとoffsetがずれる可能性があるため、ページ番号だけを永続cursorとして扱わない。各同期実行内で全対象ページを走査し、境界時刻を少し重ね、`_id`で冪等に取り込む。

### 日時と差分取得

- raindropの文書化された主フィールドには、追加日時の`created`と更新日時の`lastUpdate`がある。時刻はISO 8601形式で返る。
- 検索演算子は`created:YYYY-MM-DD`と`lastUpdate:YYYY-MM-DD`を持ち、`<`と`>`による前後指定ができる。
- changelogは、各更新で`lastUpdate`が更新されるとしている。

`occurred_at`には`created`を保存する。差分同期のwatermarkには`lastUpdate`を使うが、検索演算子の精度や同一時刻の境界取りこぼしを避けるため、前回watermarkより前から再取得する。取得時刻は別の`ingested_at`として保持する。

### URLと重複

- raindropの一意な識別子は整数の`_id`で、`link`はURLとして別フィールドになっている。
- 公式のraindropフィールドにcanonical URLはない。Import APIのURL解析結果には`meta.canonical`が現れる場合があるが、これは取得済みraindropの安定した契約ではない。
- URLの存在確認APIは既存bookmarkのIDを返せるが、取得同期の識別子をURLにする必要はない。

したがって、クエリ除去、末尾slash調整、redirect追跡など独自の正規化は行わない。`source=raindrop`と`source_id=_id`を一意キーにし、`link`は原値を保存してMarkdownへURLだけを挿入する。同じURLが複数IDとして存在してもRaindrop側の状態を尊重する。

### 更新と削除

- `lastUpdate`で、タイトル、URL、タグ、コレクション移動などの更新候補を再取得できる。取得した同じ`_id`を置換更新する。
- 通常の削除はTrashへの移動である。`GET /rest/v1/raindrops/-99`でTrashを取得できる。
- `collectionId=0`の一覧はTrashを除く。Trashからさらに削除すると永久削除される。
- 公開資料にはwebhook、削除イベント列、同期cursorは記載されていない。

インボックス自体が14日で期限切れになるため、日次同期で直近分をupsertし、Trashの該当IDを削除する運用で十分である。永久削除まで即時かつ厳密に反映する必要はなく、最大14日でインボックス側の期限削除により収束する。厳密性が必要になった場合だけ、定期全件照合を追加する。

## 推奨する最小契約

1. Test tokenをサーバーsecretとして保管し、クライアントへ渡さない。
2. `raindrops/0`を50件ずつ取得し、`_id`を一意キーとしてupsertする。
3. `created`を表示順の日時、`lastUpdate`を差分取得watermark、取得時刻を14日保持の起点にする。
4. 差分検索は境界を重ね、再取得と同一IDの再処理を許容する。
5. `link`を変更せず保存・挿入し、URL正規化による同一性判定をしない。
6. Trashを別走査して該当項目を除去する。永久削除のtombstoneは期待しない。
7. 429またはレート残量枯渇時は`X-RateLimit-Reset`を尊重し、5xxだけを後で再試行する。変更なしの4xxは再試行しない。

## 未確認事項

実アカウントのTest tokenはリポジトリ内に存在しなかったため、実レスポンスによる以下の確認は行っていない。

- `lastUpdate`検索の秒・ミリ秒指定と境界の包含関係
- ページ走査中に追加された項目がある場合の具体的な重複・欠落挙動
- Trash取得結果における元コレクション情報

これらは実装時に小さなfixture取得で確認し、同期処理は結果にかかわらず重複窓と`_id` upsertで安全側にする。

## 一次資料

- [Raindrop.io API Overview](https://developer.raindrop.io/)
- [Obtain access token](https://developer.raindrop.io/v1/authentication/token)
- [Make authorized calls](https://developer.raindrop.io/v1/authentication/calls)
- [Raindrops fields](https://developer.raindrop.io/v1/raindrops)
- [Multiple raindrops](https://developer.raindrop.io/v1/raindrops/multiple)
- [Single raindrop](https://developer.raindrop.io/v1/raindrops/single)
- [Filters and search operators](https://help.raindrop.io/filters)
- [Import API](https://developer.raindrop.io/v1/import)
- [API changelog](https://developer.raindrop.io/more/changelog)
