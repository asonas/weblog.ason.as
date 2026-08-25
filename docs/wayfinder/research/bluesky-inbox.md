# Bluesky の投稿といいねを取得する契約

調査日: 2026-08-25

## 結論

Bluesky にこの用途専用の「API キー」はない。新規のユーザー向け連携では AT Protocol OAuth が正式な第一選択であり、単一ユーザーの小規模なサーバー処理を先に作る場合に限り、App Password を `com.atproto.server.createSession` に渡す旧式セッションを暫定利用できる。主パスは OAuth の confidential web client とし、トークンをサーバー側で暗号化保存する。

投稿といいねでは取得契約を分ける。

- 自分の投稿: `com.atproto.repo.listRecords` で自分の repository の `app.bsky.feed.post` を列挙する。これなら repost が混ざる `app.bsky.feed.getAuthorFeed` より「自分が作成した投稿」という境界が明確で、投稿レコードの `createdAt` を日時にできる。
- 自分のいいね: `app.bsky.feed.getActorLikes` は認証済み本人だけが利用でき、hydrated post を返すが、返却型には「いいねした日時」がない。自分の repository の `app.bsky.feed.like` を `com.atproto.repo.listRecords` で列挙し、like レコードの `createdAt` を日時、`subject.uri` と `subject.cid` を対象投稿の識別子にする。表示情報は `app.bsky.feed.getPosts` 等で hydration する。

両方とも cursor を保存して追記取得するだけでは削除・更新を確実に反映できない。インボックスの保持期間が14日であることを利用し、同期ごとに14日窓の現行レコード集合を再取得して、AT URIを主キー、CIDを版として照合する。消えたAT URIは削除、同じAT URIでCIDが変われば更新とする。全ネットワークのfirehose購読はこの規模では不要である。

## 取得契約

### 認証

AT Protocol OAuth はユーザー向けソフトウェアの主要な認証方式で、webサービスも対象になる。confidential client は公開された client metadata と署名鍵を持ち、アクセストークン、更新トークン、DPoP鍵を安全に保持する。固定APIキーを保存する設計にはしない。

App Password は通常のパスワードと同様に `createSession` へ渡し、制限付きの access JWT と refresh JWT を得る方式である。OAuth移行前の最小実装には使えるが、ユーザーの本パスワードは保存しない。

### ページングと期間

`listRecords` と `getActorLikes` は cursor ページングである。`listRecords` は `reverse=true` でrecord keyの降順に読み、同期処理は応答の cursor がなくなるまで、または14日窓より古いレコードへ到達するまで進める。cursor は不透明値として扱う。

初回および定期的な整合処理では `listRecords` を新しい順に読み、次を保存する。

- source record URI（post または like の AT URI）
- source record CID
- 対象postの AT URI と CID（likeでは `subject`）
- source recordの `createdAt`
- 取得時刻

### 日時

- 自分の投稿: `app.bsky.feed.post.createdAt`
- 自分のいいね: `app.bsky.feed.like.createdAt`

どちらもクライアント宣言値であり、サーバーが保証した監査時刻ではない。日記用の表示日時としては要件を満たすが、欠損・不正値に備えて取得時刻へのfallbackを持つ。

### 埋め込み

対象投稿は永続的な識別子として AT URI を保存し、表示用に canonicalな `https://bsky.app/profile/<did-or-handle>/post/<rkey>` URLを導出する。Bluesky公式web実装は `https://embed.bsky.app/oembed` からHTMLを取得でき、生成されるblockquoteは `data-bluesky-uri`、`data-bluesky-cid` と `https://embed.bsky.app/static/embed.js` を使う。

エディタへ挿入する時点でサーバー側からoEmbed HTMLを取得する。収集時のHTMLを14日保存すると、投稿更新や削除、埋め込み仕様変更で古くなるためである。外部HTMLなので、既存のMarkdown/HTML保存・sanitize契約との適合は別の意思決定で確認する。

### 更新・削除・ unlike

AT Protocol repositoryでは同じrecord keyの更新によりCIDが変わり、削除はrecord自体がなくなる。削除には恒久的なtombstoneが残らない。likeも独立した `app.bsky.feed.like` recordなので、unlikeはそのrecordの削除で表現される。

14日窓の集合照合では次のように扱う。

- post recordが消えた: インボックス項目を削除する
- post AT URIが同じでCIDが変わった: 内容を再hydrateして更新する
- like recordが消えた: 対応する「いいね」項目を削除する
- likeの対象postが削除・非表示・ブロック等でhydrateできない: インボックスには挿入不能として残さず削除する

firehoseの `com.atproto.sync.subscribeRepos` はcreate/update/deleteを低遅延に追えるが、全ネットワークstreamの運用、CBOR処理、cursor復旧が必要になる。14日・単一アカウント・日記用途では定期pollingと集合照合の方が小さい。

## 実装へ渡す最小仕様

1. Bluesky接続はOAuth confidential clientを目標契約とし、暫定導入だけApp Passwordを許容する。
2. post/like collectionを新しい順にpollし、14日窓を毎回集合照合する。
3. AT URIを一意キー、CIDを更新検知キーにする。投稿といいねは別項目として扱う。
4. いいね日時は `getActorLikes` の応答から推測せず、like recordの `createdAt` を使う。
5. 埋め込みHTMLはエディタ挿入時に公式oEmbedから取得する。

## 一次資料

- [AT Protocol OAuth仕様](https://atproto.com/specs/oauth)
- [AT Protocol XRPCとApp Password](https://atproto.com/specs/xrpc)
- [SDK authentication guide](https://atproto.com/guides/sdk-auth)
- [`app.bsky.feed.getActorLikes` Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/getActorLikes.json)
- [`app.bsky.feed.post` Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/post.json)
- [`app.bsky.feed.like` Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/app/bsky/feed/like.json)
- [`com.atproto.repo.listRecords` Lexicon](https://github.com/bluesky-social/atproto/blob/main/lexicons/com/atproto/repo/listRecords.json)
- [Repository仕様](https://atproto.com/specs/repository)
- [Sync仕様](https://atproto.com/specs/sync)
- [Bluesky公式web実装のembed定数](https://github.com/bluesky-social/social-app/blob/main/src/lib/constants.ts)
- [Bluesky公式web実装のembed README](https://github.com/bluesky-social/social-app/blob/main/bskyweb/README.embed.md)
