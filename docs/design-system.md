# weblog.ason.as design system

この文書は、公開画面とエディタをCover Journalの視覚方向で実装するときに、人間とエージェントが共有する最小の規範です。新しい汎用UIライブラリではありません。今回の対象画面に必要な語彙だけを定義します。

開発環境では `/design-system` に部品と状態の見本を表示します。この画面は実データと認証状態へ依存せず、本番では有効になりません。

## 原則

- カバーと背景は画面端まで伸ばし、文章と操作部品には内側余白を残す
- 編集画面では本文を先頭側へ寄せ、素材欄との2カラムにする。閲覧画面では本文を中央へ置く
- 視覚的な個性は大きなカバーとタイトルへ集約し、本文と操作部品は静かに保つ
- 既存の記事テーマを維持し、部品から生の色を参照しない
- 線より余白でまとまりを示す。影は面の重なりを示す場合だけ使う
- 比較用の `?variant` や `?panel`、旧UI互換層を本番へ持ち込まない

## 色

テーマごとに次の意味トークンを定義します。

公開画面の現在の配色は、CanvasとCardが白、SurfaceとQuiet fillが薄いグレー、Inkが黒、補助文字が濃いグレーです。リンク・フォーカス・タグの文字には青を使います。管理画面の状態色はこの公開用パレットに含めません。`/design-system` は公開画面と同じテーマ定義を使います。

| Token | Role |
| --- | --- |
| `--canvas` | ページ全体の背景 |
| `--surface` | 本文やパネルの面 |
| `--card-surface` | カードとして区別する面 |
| `--ink` | 通常の文字と主要な輪郭 |
| `--muted-ink` | 補助情報 |
| `--quiet-fill` | 控えめな選択・ホバー面 |
| `--accent` | 選択、リンク、主要状態 |
| `--accent-ink` | accent上の文字 |
| `--separator` | 記事内の区切りなど、判別できる必要がある境界線 |
| `--separator-subtle` | 補助的な境界線 |
| `--focus-ring` | キーボードフォーカス |
| `--quotation-surface` | 日記からの引用領域。淡い黄緑 `#EBF0DC` |
| `--tag-surface` / `--tag-ink` | タグ |

カバー上の文字は白を基本とし、画像へ暗いオーバーレイを重ねます。状態を色だけで伝えず、文字、枠、形、読み上げ状態を併用します。

### Ableton — 原典パレット

ユーザー提供の「Ableton — Style Reference」を原典として保持します。
白い紙面・黒い文字・青いリンクを基本に、CoralとTealはカテゴリーの塗りに使います。
これらの値を追加参考色で置き換えません。公開サイトへの適用は用途別トークンで行います。

| 名前 | 値 | 原典トークン | 用途 |
| --- | --- | --- | --- |
| Signal Blue | `#0000ff` | `--color-signal-blue` | リンクなどインタラクティブな文字。塗りの主CTA色にはしない |
| Coral | `#ff8389` | `--color-coral` | カテゴリーの塗り（Downloads、News） |
| Teal | `#00d2be` | `--color-teal` | カテゴリーの塗り（Tutorials、Videos） |
| Ink | `#000000` | `--color-ink` | 本文・見出し・ナビゲーション・アイコン |
| Fog | `#eeeeee` | `--color-fog` | 入力欄や控えめな補助面 |
| Paper | `#ffffff` | `--color-paper` | ページとカードの背景、写真上の文字 |

### Ableton — 追加参考パレット

以下は2026-10-01にAbletonの各ページのCSSから確認したベタ色です。用途未定の参考色として保持し、採用する場合に用途別の意味トークンへ割り当てます。

| 色 | 値 | 出典 |
| --- | --- | --- |
| ラベンダー | `#CDBEFD` | [Live](https://www.ableton.com/ja/live/) |
| ピーチ | `#FFC3A5` | [Shop](https://www.ableton.com/ja/shop/) |
| 淡い黄色 | `#FDFFD9` | [Note](https://www.ableton.com/ja/note/) |
| 明るい黄緑 | `#B6FFC0` | [Live](https://www.ableton.com/ja/live/)の更新告知 |
| 淡い黄緑 | `#EBF0DC` | [Live](https://www.ableton.com/ja/live/)の「無限に溢れ出すアイデア」 |
| 緑 | `#41CE97` | [Push](https://www.ableton.com/ja/push/)の機能アコーディオン |
| ミントティール | `#8EFBD8` | [Note](https://www.ableton.com/ja/note/)の「Liveでさらに発展させる」 |
| 黒に近い紺 | `#030512` | [Push](https://www.ableton.com/ja/push/)のアーティスト見出し |
| 黒・白・グレーの組 | `#000000` / `#FFFFFF` / `#818181` | [Push](https://www.ableton.com/ja/push/)のアーティスト選択領域 |

## 文字

新しいWebフォントは追加せず、現在のシステムフォントを使います。

| Token | Value | Role |
| --- | --- | --- |
| `--text-cover-title` | `clamp(2.8rem, 7vw, 6rem)` | カバータイトル |
| `--text-page-title` | `clamp(2rem, 5vw, 3.5rem)` | 通常ページタイトル |
| `--text-heading-lg` | `1.75rem` | 大見出し |
| `--text-heading-md` | `1.25rem` | 中見出し |
| `--text-body` | `1rem` | 本文、行高1.75 |
| `--text-ui` | `0.875rem` | UIラベル |
| `--text-meta` | `0.75rem` | 日付と補助情報 |

長文は `--measure-content` の52remを上限とします。大きなタイトルは `text-wrap: balance` を使い、本文の字間は詰めません。

## 余白と形状

余白は `--space-1 / 2 / 3 / 4 / 6 / 8 / 12 / 16` を使います。値は4、8、12、16、24、32、48、64pxです。画面端へ密着するカバー、メニュー、素材欄だけ余白0を許可します。

- `--radius-control`: 4px。ボタンと入力
- `--radius-media`: 8px。カードと画像
- `--radius-round`: 円形操作
- `--border-width`: 1px。通常の境界線

## レイアウト

| Token | Value | Role |
| --- | --- | --- |
| `--measure-content` | `52rem` | 本文最大幅 |
| `--cover-height` | `21.875rem` | 約350pxのカバー |
| `--material-panel-width` | `22rem` | 素材リスト |
| `--material-tabs-width` | `3.5rem` | 縦タブ |
| `--cover-title-overlap` | `9rem` | タイトルとカバーの重なり |

52rem以下では素材欄を下部シートへ切り替えます。ブレークポイントは一般的な端末幅ではなく、本文と素材欄が同時に成立しなくなる幅として扱います。

## 対象部品と状態

対象はカバー、本文組版、素材パネル、縦タブ、写真グリッド、Raindropカード、ボタンです。通常、ホバー、フォーカス、選択、空、読込中、無効状態を確認します。

WYSIWYG内部の細かな挙動、ユニバース、管理画面はこの規範の対象外です。既存画面を一括置換せず、UI刷新の対象となる画面から適用します。

## 本文中の引用

Markdownの引用（`>`）には `--quotation-surface` の背景、2pxの `--muted-ink` の左線、`--space-4` の内側余白を使います。公開ページと編集プレビューで同じスタイルを使い、引用内の文字サイズ・行高は本文を継承します。長い出典URLは引用の幅で折り返します。

## 日記からの引用

記事への言及は「Mentioned by days」として、かけらごとに全文と写真を表示します。各引用の上に日付リンクを置き、元の日記の該当かけらへ移動できるようにします。日付見出しと出典リンクを重複させません。

引用領域の背景には `--quotation-surface` を使います。2026-10-01に[Ableton Live](https://www.ableton.com/ja/live/)の「無限に溢れ出すアイデア」領域のCSSから確認したベタ色 `#EBF0DC` を採用しました。ラベンダー `#CDBEFD`、[Shop](https://www.ableton.com/ja/shop/)のピーチ `#FFC3A5`、[Note](https://www.ableton.com/ja/note/)の淡い黄色 `#FDFFD9` も参考パレットとして残します。画像やスクリーンショットからの採色ではありません。

引用は本文と同じ文字サイズ・行高を使い、左側の細い `--muted-ink` の線と `--space-4` の余白で示します。日付も背景上のコントラストを確保するため `--ink` を使い、小さい文字サイズで補助情報として示します。日付の違うグループは細い横線と上下の余白で区切ります。同じ日付のかけら同士は横線を入れず、`--space-8` の余白で区切り、写真は引用の幅に収めます。本文が空の記事では本文用の余白を確保せず、引用をタイトルの下に続けます。

## アクセシビリティの下限

- ネイティブ要素を優先する
- フォーカスリングは2px以上で、面の色が変わっても視認できるようにする
- タッチ対象は44px以上にする
- 200%ズームと幅320pxで操作可能にする
- 動きは `prefers-reduced-motion` を尊重する
- 装飾画像は空の代替テキスト、操作画像は操作結果を名前にする
