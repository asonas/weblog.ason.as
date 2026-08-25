# c4p.ason.as の投稿取得とプレイヤー埋め込み契約

調査日: 2026-08-25

## 結論

インボックスの取得口には、公開済みかつ再生可能なトラックだけを列挙する
`https://c4p.ason.as/feed.xml` を使う。各 item の `guid` をソース内の安定ID、
`pubDate` を表示・整列用の投稿日時として扱い、`guid` で upsert する。

エディタへ挿入して保存する表現は、次の canonical permalink だけとする。

```markdown
https://c4p.ason.as/t/<guid>
```

公開時には weblog.ason.as がこの URL を c4p 専用プレイヤーへ変換する。
現行 c4p には oEmbed や専用 iframe endpoint がなく、permalink を iframe に
入れると一覧SPA全体が表示されるため、iframe HTML を保存契約にはしない。

プレイヤーは permalink の UUID をキーに c4p の公開情報を解決し、少なくとも
タイトル、説明、長さ、MP3 enclosure URL、permalink を表示する。再生要素には
`<audio controls preload="none">` を使う。ウェーブフォームは必須契約にせず、
必要になった時だけ `/api/tracks` の `waveformKey` を使う拡張とする。

## 取得契約

`feed.xml` は RSS 2.0 と iTunes 拡張の公開フィードで、各 item に次を持つ。

| インボックスの値 | RSSの値 | 用途 |
| --- | --- | --- |
| `source` | 固定値 `c4p` | ソース種別 |
| `source_id` | `guid` | c4p内の安定ID、upsertキー |
| `occurred_at` | `pubDate` | 投稿日時と時系列表示 |
| `canonical_url` | `link` | 保存するpermalink |
| `title` | `title` | 一覧とプレイヤー表示 |
| `description` | `description` | 一覧とプレイヤー表示 |
| `media_url` | `enclosure@url` | MP3再生 |
| `media_type` | `enclosure@type` | 現行値は `audio/mpeg` |
| `media_bytes` | `enclosure@length` | 任意の表示・検証 |
| `duration` | `itunes:duration` | 再生時間表示 |
| `image_url` | `itunes:image@href` | 任意のカード表示 |

現行データでは `guid` と API の `id` は同じ UUID で、permalink、MP3、OGPも
同じ UUID から組み立てられている。`pubDate` は DynamoDB へ作成時に保存される
`createdAt` の変換値であり、タイトルに含まれる日付ではない。したがって、ユーザーが
指定した「c4pへ投稿された日」には `pubDate` を使う。

フィードは認証不要で、公開済みかつ処理状態が `ready` の項目だけを含む。
取得側はフィード全体を定期取得し、`source = c4p` と `source_id = guid` の組で
upsertする。14日保持の起点は共通インボックス側の `ingested_at` とし、
`occurred_at` とは分ける。フィードから消えた項目の即時削除は必須にせず、
共通の14日削除へ任せる。

`/api/tracks` も同じ公開対象を返し、`createdAt`、`audioKey`、`waveformKey`、
`ogpKey`、`durationSec` を取得できる。ただし、インボックスに必要な最小情報は
RSSに揃っており、RSSにはcanonical permalinkと絶対MP3 URLも含まれる。
そのためAPIはプレイヤーの追加表現が必要になった場合の補助に留める。

## 埋め込み境界

現行 weblog.ason.as の Markdown renderer は raw HTML をエスケープし、
`audio` と `iframe` を許可していない。そのためインボックスが `<audio>` や
`<iframe>` を本文へ直接挿入しても、公開ページのプレイヤーにはならない。

実装段階では canonical c4p URL の独立行を認識する専用の Markdown 表現を
weblog側に追加する必要がある。これにより、本文は可搬なURLのまま残り、表示用HTML、
アクセシビリティ、将来のプレイヤー変更をrenderer側に閉じ込められる。

インボックスから本文へドロップできた時点で項目は使用済みとしてインボックスから
除去できる。c4p の音声本体は元サービスの公開資産なので、写真のようなS3移動は
行わない。

## 確認した一次資料

- [c4p 公開RSS](https://c4p.ason.as/feed.xml)
- [c4p 公開トラックAPI](https://c4p.ason.as/api/tracks)
- [c4p の Track domain](https://github.com/asonas/c4p.ason.as/blob/main/server/src/domain.ts)
- [c4p の公開routeとfeed生成](https://github.com/asonas/c4p.ason.as/blob/main/server/src/app.ts)
- [c4p のRSS field生成](https://github.com/asonas/c4p.ason.as/blob/main/server/src/feed.ts)
- [c4p の現行プレイヤー](https://github.com/asonas/c4p.ason.as/blob/main/web/src/components/TrackCard.tsx)
- [weblog の安全なMarkdown変換](../../../lib/weblog_authoring/markdown.rb)
