---
name: verify-draft-sync
description: エディタの下書き保存（端末のIndexedDBとサーバーへの同期、通信断と応答消失からの再送、別端末とのタイトル競合）で、保存済み表示が嘘にならず、同じ変更が二度当たらず、別端末のタイトルを黙って上書きしないことを、TLA+モデルの全探索で確かめる。frontend/authoring/draftSession.ts の changed・persist・sync・syncLocked・catchUp・mergeMetadata・resolveMetadata・uploadFlight、または lib/weblog_authoring/draft_store.rb の begin_upload・commit_upload・append_data・merge_metadata を変更したとき、または下書き同期の検証を頼まれたときに使う。
---

# Verify draft sync

性質: 作者が下書きを書き、通信が切れ、応答が失われ、別端末がタイトルを変えても、(1)「サーバーに保存済み」の表示はサーバーの内容と一致し、(2) サーバーにある本文は端末にも書き終えていて、(3) 再送した変更は一度しか当たらず、(4) 別端末のタイトルは作者が選ばない限り上書きされない。
破れたときの害: 作者が保存済みと信じてタブを閉じたあと本文やタイトルが失われる、同じ段落が二重になる、または別端末で直したタイトルが知らないうちに古い値へ戻る。

この検証は `draftSession.ts` や `draft_store.rb` を実行しない。検査するのは `DraftSync.tla` のモデルだけである。対象の関数を変えたのにモデルの対応する動作を直さなければ、検証は通っても何も保証しない。下の「変更が対象か判断する」の手順2を飛ばさない。

## 変更が対象か判断する

1. 同期コミットからの差分を見る。何か出れば、この検証の対象になる変更である。

   ```sh
   git --no-pager diff 81a8587 -- frontend/authoring/draftSession.ts lib/weblog_authoring/draft_store.rb
   ```

2. 差分が下の「対応表」の関数や行に触れていれば、対応するモデルの動作を読み、コードと同じ振る舞いになっているか確かめる。違えば「意図した変更で検証を更新する」に従ってモデルを直してから実行する。触れていない（表示文言、ピース形式だけの処理など）なら、実行して基準値と同じことを確かめれば足りる。

## 実行する

1. 作業worktreeのルートで次を実行する。初回は mise が Temurin 21 と tla2tools.jar 1.7.4（sha256で固定）を入れるのでネットワークを使う。2回目以降は約5秒で終わる。Node、Ruby、AWS認証は使わない。

   ```sh
   .agents/skills/verify-draft-sync/check.sh
   ```

2. 最終行の `要約:` を下の基準値と比べる。規則ごとに別々にTLCを実行するので、1つの違反が他の規則の結果を隠さない。違反が1件でもあれば終了コードは1になる。
3. 範囲を広げるときは `check.sh <MaxEdits> <MaxRev>` を渡す。既定（3と3）より小さい値の結果を合格の根拠にしない。`5 4`（33,332状態）でも約5秒で終わり、規則はすべて成立した。

## 結果を読む

基準値（81a8587、既定の範囲）:

```text
要約: SavedMeansOnServer=成立 DeviceFirst=成立 AppliedOnce=成立 NoSilentOverwrite=成立 状態数=7444 (MaxEdits=3 MaxRev=3)
```

- `違反` の規則には、TLCの反例が状態の列として表示される。反例と、それがモデルのどの状態でどの規則を破ったかは、必ず `/statechart` スキルで読む。`/statechart` は違反の最短経路を作者の言葉の手順にし、違反がなければ状態の移り方を図にする。`/statechart` の実行方法はそのスキルに従い、このスキルには写さない。
- `デッドロック` は、どの動作も取れない状態に達したことを表す。モデルの動作の条件を狭めすぎたときに起きる。
- `実行エラー` は、モデルの構文や型の誤りである。TLCの出力をそのまま読む。
- 状態数が基準値から大きく変わったときは、変更がモデルの状態空間に影響している。規則がすべて成立していても、変更とモデルの差を説明できるか確かめる。

各規則の意味（`DraftSync.tla` の末尾）:

| 規則 | 一文での意味 |
| --- | --- |
| `SavedMeansOnServer` | 「サーバーに保存済み」と表示しているなら、本文と作者のタイトルはサーバーにある（その後に別端末がタイトルを変えた場合を除く）。 |
| `DeviceFirst` | サーバーにある本文は、端末にも書き終えている。 |
| `AppliedOnce` | 送信を再試行しても、同じ変更を二度当てない。 |
| `NoSilentOverwrite` | 別端末で変えたタイトルを、作者が選ばずに上書きしない。 |

### 既知の発見

違反はない。次の挙動は規則にしていない観察で、ユーザーが仕様かどうかをまだ決めていない。決まったら規則にするか、ここから消す。

1. タイトルの競合が未解決の間、本文もサーバーへ送られない。`syncLocked` は `catchUp` の後の `if (this.metadataConflicts.length && !this.flight) return;`（`draftSession.ts:1309`）で同期全体を止める。本文は端末には残る。この間は `preparePublication` も公開を拒む。モデルでは `SyncStarts` が `"conflict"` を表示して送信しない枝に当たる。

### 実バグとモデルの誤りを見分ける

- 反例を `/statechart` で読み、手順を対応表のコードで1つずつたどる。たどれない手順があれば、モデルの誤りを先に疑う。81a8587 でこのモデルを作ったとき、応答を失った後の再送でサーバーが返すreceiptの版数をモデルが誤って最新にしていたため `SavedMeansOnServer` が偽の違反を出した。実際のサーバーは保存時点のreceiptを返す（`draft_store.rb:237`、`:282`、`:319`）。
- 反例が `TheOtherDeviceChangesTheTitle` を含むなら、別端末が同じフィールドを書いたときにだけ起きる。含まないなら、1つのタブの操作と通信の失敗だけで起きる。
- 反例が `TheUploadIsAppliedButTheReplyIsLost` を含むなら、サーバーの重複判定（`update_id` と `draft_updates.receipt`）に依存している。
- コードでたどれた反例は実バグとして、手順を作者の操作の言葉で報告する。製品コードはユーザーが頼んだときだけ直す。規則やモデルを弱めて違反を消さない。

## 対応表

モデルは `DraftSync.tla`。1つの動作は、コードで割り込まれずに進む単位（JavaScriptの1回の非同期の継続、またはサーバーの1回のDBトランザクション）に対応する。

| モデルの動作・定義 | 実コード |
| --- | --- |
| `YouType` | `DraftSession#changed`（`draftSession.ts:1028`）。本文の編集が `revision` を増やし、`serverStatus` を「未送信の変更あり」にする |
| `YouChangeTheTitle` | `DraftSession#setMetadata`（`draftSession.ts:1008`）→ `changed` |
| `TheDeviceWriteFinishes` | `DraftSession#persist`（`draftSession.ts:1084`）。IndexedDBへの書き込みが終わり `persistedRevision` が `revision` に追いつく |
| `TheOtherDeviceChangesTheTitle` | 別端末の `DraftStore#append_data`・`#merge_metadata`（`draft_store.rb:308`、`:577`）。タイトルの `revision` を1増やす |
| `TheNetworkDrops`・`TheNetworkReturns` | ブラウザの通信断と `online` イベント（`draftSession.ts:504` の `refresh`） |
| `SyncStarts` | `DraftSession#sync`（`:1120`）→ `#syncLocked`（`:1294`）。`persistedRevision !== revision` なら戻る（`:1302`）。flightがなければ `catchUp(true)`（`:1307`）で `mergeMetadata` し、競合があれば戻る（`:1309`）。flightを作るとき、変えたフィールドに `expected_revision: this.serverMetadata[field].revision`（`:1357`）を付ける。「サーバーに保存中」にする |
| `Merge` | `DraftSession#mergeMetadata`（`:691`）のタイトル分 |
| `StatusAfter` | `DraftSession#catchUp` 末尾の `serverStatus` の決定（`:684-688`） |
| `TheSyncCannotReachTheServer` | `catchUp` の要求が status 0 で失敗し、`syncLocked` の catch（`:1455` 以降）が「サーバー保存を確認できません」にする |
| `TitleFresh` | `DraftStore#merge_metadata` の `expected_revision` 照合（`draft_store.rb:580`）。保存済みreceiptがあれば照合の前に返る |
| `Apply` | `DraftStore#begin_upload`（`:225`、既存receiptを返す `:237`）、`#commit_upload`（`:275`、`:282`）、`#append_data`（`:308`、`:319`）。receiptのない `update_id` だけ本文とタイトルを当て、`draft_updates` にreceiptを保存する |
| `TheUploadSucceeds` | `DraftSession#uploadFlight`（`:1486`）が一致するreceiptを受け取った後の `syncLocked`（`:1428-1451`）。`receipt.metadata` を `serverMetadata` にし（`:1447`）、flightに含めなかったフィールドだけ手元を合わせ、flightを捨て、`catchUp(true)`（`:1451`）で再度mergeする |
| `TheUploadIsAppliedButTheReplyIsLost` | サーバーはreceiptを保存したが応答が届かない。flightはIndexedDBに残り、同じ `update_id` で再送される |
| `TheUploadDoesNotArrive` | `uploadFlight` が status 0 で失敗し、catch が一時的な失敗として再試行を予約する（`:1459` の `isTransient`） |
| `TheServerRejectsTheStaleTitle` | 409 `Metadata conflict:`（`draft_store.rb:580`）。`syncLocked`（`:1415-1424`）がflightを捨て、`catchUp` で競合を表示する。本文の編集は `this.pending` に残る |
| `YouKeepTheOtherTitle`・`YouKeepYourTitle` | `DraftSession#resolveMetadata(field, "remote" / "local")`（`:740`）。flightがある間は何もしない。保存していた競合の値と版数を `serverMetadata` にし、`changed` を呼ぶ |

## 範囲と前提

探索の範囲:

- 本文の編集は最大 `MaxEdits` 回（既定3）。サーバーのタイトルの版数は最大 `MaxRev`（既定3）で、それを超える状態は探索しない（`CONSTRAINT Bound`）。
- タイトルの値は「初期値」「作者の題」「別端末の題」の3つ。別端末はタイトルだけを変える。
- 通信は何度でも切れて戻る。送信中の応答は、届く、サーバーで当たったが失われる、届かない、のいずれかになる。

前提（本番との違い）:

- 本文はYjsの差分ではなく編集回数で表す。CRDTの合流は正しいものとし、確かめない。
- メタデータはタイトルだけを扱う。`page_type`・`page_date`・カバー設定も同じ `mergeMetadata` と `expected_revision` を通るが、フィールド間の制約（日記のタイトルと日付の一致など）は扱わない。
- タブは1つ。`navigator.locks` の `draft-sync:<id>` が同じ記事の同期を直列にするので、`sync` は送信中に重ならないとする（`sending`）。
- `PUT ""`（`:1315`）による記事の作成、チャンク分割（`upload_chunk`）、`catchUp` のページング、checkpointは、成功するものとして扱う。

対象外:

- 複数タブ（`readShared`、`BroadcastChannel`、`tabConflicts`）。
- IndexedDBへの書き込み失敗（「端末に保存できません」）と `failedBase`。
- 512 KiBの上限、カバー設定の400・422、`Draft changed; retry this update` の409など、一時的でない失敗による `isBackgroundPaused`。
- ピース形式の構造（`/structure` のPATCH、`pieces.conflicts`）とlegacyからの移行。
- 日本語IMEの変換中（`isComposing`）、タブを閉じる操作（`isClosed`）。
- 公開（`preparePublication`、`publish`）。公開処理側の検証は別のスキルが扱う。

## 壊して確かめた記録（81a8587）

各規則が破れを見つけられることを、コードの破れに対応するようにモデルを一時的に変えて確かめた。どれも確認後にモデルを元に戻し、要約が基準値に戻ることを確かめた。

| 一時的な変更（対応するコードの破れ） | 要約 |
| --- | --- |
| `Apply` が保存済みreceiptを無視する（`begin_upload`・`commit_upload`・`append_data` のreceipt参照を消す） | `AppliedOnce=違反`、`NoSilentOverwrite=違反`。応答を失った再送が本文とタイトルをもう一度当て、その間に別端末が書いたタイトルを古い値で上書きする |
| `TitleFresh == TRUE`（`merge_metadata` の `expected_revision` 照合を消す） | `NoSilentOverwrite=違反` |
| `SyncStarts` から `onDevice = typed` を外す（`syncLocked` の `persistedRevision !== revision` の早期returnを消す） | `DeviceFirst=違反`。端末に書き終える前の本文がサーバーに届く |
| `StatusAfter` が未送信の変更を見ない（`catchUp` 末尾の `hasPendingChanges()` の分岐を消す） | `SavedMeansOnServer=違反` |

実コードでの確認: `draft_store.rb` の `merge_metadata` から `expected_revision` の照合行（`:580`）を一時的に消し、このスキルの手順どおりに進めた。差分確認で `merge_metadata` が出て、対応表から `TitleFresh` を `TRUE` に直し、`check.sh` が `NoSilentOverwrite=違反` を出した。`/statechart` で読むと、作者がタイトルを変えて同期を始めた後に別端末がタイトルを変え、作者の送信が古い `expected_revision` のまま受け付けられて別端末の題を上書きする経路だった。コードとモデルを戻し、`git status` で差分がないことと、要約が基準値に戻ることを確かめた。

## 意図した変更で検証を更新する

- 対応表の関数の振る舞いが変わったら、対応する動作を同じ変更で直し、対応表の行番号も更新する。動作の単位（割り込まれずに進む範囲）がコードとずれないようにする。
- 違反を消すために規則を弱めたり、動作の条件を足したりしない。コードの振る舞いと違う条件を足すと、モデルが実際に起きることを探索しなくなる。ユーザーが挙動を仕様として受け入れた場合だけ、その判断と日付を「既知の発見」に書き、基準値を更新する。
- 新しい動作や規則を足したら、対応するコードを壊した版のモデルで新しい規則が `違反` になることを一度確かめ、元に戻す。
- `check.sh` のツールの版（Temurin 21、tla2tools 1.7.4 とそのsha256）を変えるときは、基準値の状態数が変わらないことを確かめる。

## 同期記録

- 同期コミット: 81a8587
- 検証した範囲: `frontend/authoring/draftSession.ts`（`changed`、`setMetadata`、`persist`、`sync`、`syncLocked`、`catchUp` の `serverStatus` 決定、`mergeMetadata`、`resolveMetadata`、`uploadFlight`、`hasPendingChanges`）、`lib/weblog_authoring/draft_store.rb`（`begin_upload`、`commit_upload`、`append_data`、`merge_metadata`）
- 同期コミットは、そのコミットで対応表と前提がコードを正しく表していることを確かめてから進める。`check.sh` を実行しただけ、または結果が基準値と同じだっただけでは進めない。
