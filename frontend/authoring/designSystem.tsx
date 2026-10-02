import type { ReactNode } from "react";

const COLOR_TOKENS = [
  ["Canvas", "--canvas"],
  ["Surface", "--surface"],
  ["Card", "--card-surface"],
  ["Ink", "--ink"],
  ["Muted ink", "--muted-ink"],
  ["Accent", "--accent"],
  ["Separator", "--separator"],
  ["Subtle separator", "--separator-subtle"],
  ["Focus", "--focus-ring"],
  ["Quiet fill", "--quiet-fill"],
  ["Quotation", "--quotation-surface"],
] as const;

const SPACING_TOKENS = [
  ["1", "4px"],
  ["2", "8px"],
  ["3", "12px"],
  ["4", "16px"],
  ["6", "24px"],
  ["8", "32px"],
  ["12", "48px"],
  ["16", "64px"],
] as const;

function PatternSection({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="design-system__section">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

export function DesignSystemPage() {
  return (
    <article className="design-system-page">
      <header className="design-system__intro">
        <p>weblog.ason.as</p>
        <h1>Design system</h1>
        <p>Cover Journalを実装するときの、最小の視覚語彙と状態見本です。</p>
      </header>

      <div className="design-system__main">
        <PatternSection title="Cover and type">
          <div className="design-system__cover">
            <span>Diary</span>
            <strong>2026-08-28</strong>
          </div>
          <div className="design-system__type-samples">
            <h3>記事を書く場所と、記事を読む場所をひとつの風景にする</h3>
            <h4>本文の見出し</h4>
            <p>
              本文は最大52remに収め、長い日本語でも行を追いやすい幅と行間を保ちます。背景と画像は画面端まで伸ばし、文章には内側の余白を残します。
            </p>
            <small>2026-08-28 21:40</small>
          </div>
        </PatternSection>

        <PatternSection title="Color roles">
          <p>
            公開画面は白・黒・薄いグレーを基本に、リンクとフォーカスに青を使います。
          </p>
          <ul className="design-system__swatches">
            {COLOR_TOKENS.map(([label, token]) => (
              <li key={token}>
                <span
                  style={{ background: `var(${token})` }}
                  aria-hidden="true"
                />
                <strong>{label}</strong>
                <code>{token}</code>
              </li>
            ))}
          </ul>
        </PatternSection>

        <PatternSection title="Ableton — Original palette">
          <p>原典の配色です。追加参考色とは区別して保持します。</p>
          <ul className="design-system__swatches">
            {[
              ["Signal Blue", "#0000ff", "Brand · インタラクティブな文字"],
              ["Coral", "#ff8389", "Accent · カテゴリーの塗り"],
              ["Teal", "#00d2be", "Accent · カテゴリーの塗り"],
              ["Ink", "#000000", "Neutral · 本文・見出し・アイコン"],
              ["Fog", "#eeeeee", "Neutral · 控えめな補助面"],
              ["Paper", "#ffffff", "Neutral · ページの背景"],
            ].map(([label, color, role]) => (
              <li key={label}>
                <span style={{ background: color }} aria-hidden="true" />
                <strong>{label}</strong>
                <code>{color}</code>
                <small>{role}</small>
              </li>
            ))}
          </ul>
        </PatternSection>

        <PatternSection title="Ableton — Additional color references">
          <p>
            ページのベタ背景から選んだ参考パレットです。引用には淡い黄緑を使い、他の色は用途を固定せず残します。
          </p>
          <ul className="design-system__swatches">
            {[
              [
                "Lavender",
                "#CDBEFD",
                "Live",
                "https://www.ableton.com/ja/live/",
              ],
              ["Peach", "#FFC3A5", "Shop", "https://www.ableton.com/ja/shop/"],
              [
                "Pale yellow",
                "#FDFFD9",
                "Note",
                "https://www.ableton.com/ja/note/",
              ],
              [
                "Light green",
                "#B6FFC0",
                "Live",
                "https://www.ableton.com/ja/live/",
              ],
              [
                "Pale yellow-green",
                "#EBF0DC",
                "Live",
                "https://www.ableton.com/ja/live/",
              ],
              ["Green", "#41CE97", "Push", "https://www.ableton.com/ja/push/"],
              [
                "Mint teal",
                "#8EFBD8",
                "Note",
                "https://www.ableton.com/ja/note/",
              ],
              [
                "Near black",
                "#030512",
                "Push · Monochrome",
                "https://www.ableton.com/ja/push/",
              ],
              [
                "Black",
                "#000000",
                "Push · Monochrome",
                "https://www.ableton.com/ja/push/",
              ],
              [
                "White",
                "#FFFFFF",
                "Push · Monochrome",
                "https://www.ableton.com/ja/push/",
              ],
              [
                "Gray",
                "#818181",
                "Push · Monochrome",
                "https://www.ableton.com/ja/push/",
              ],
            ].map(([label, color, source, href]) => (
              <li key={color}>
                <span style={{ background: color }} aria-hidden="true" />
                <strong>{label}</strong>
                <code>{color}</code>
                <a href={href}>{source}</a>
              </li>
            ))}
          </ul>
        </PatternSection>

        <PatternSection title="Article quotations">
          <div className="ProseMirror public-article-body">
            <p>本文と引用を、背景色と左の線で区別します。</p>
            <blockquote>
              <p>はてなに関する新機能等を発表したときの決まり文句。</p>
              <p>
                <a href="https://d.hatena.ne.jp/">引用元へのリンク</a>
              </p>
            </blockquote>
          </div>
        </PatternSection>

        <PatternSection title="Diary quotations">
          <div className="article-workspace--reading design-system__quotation">
            <section
              className="mentioned-by-days"
              aria-labelledby="quotation-example-heading"
            >
              <h2 id="quotation-example-heading">Mentioned by days</h2>
              <section className="mentioned-by-days__day">
                <figure className="mentioned-by-days__piece">
                  <figcaption>
                    <a href="/2026-10-01" aria-label="2026-10-01の日記へ">
                      <time dateTime="2026-10-01">2026-10-01</time>の日記を見る
                    </a>
                  </figcaption>
                  <blockquote cite="/2026-10-01">
                    <div className="ProseMirror public-article-body">
                      <p>
                        最近、新しいキーボードを使い始めた。毎日書く場所が少し心地よくなった。
                      </p>
                    </div>
                  </blockquote>
                </figure>
              </section>
              <section className="mentioned-by-days__day">
                <figure className="mentioned-by-days__piece">
                  <figcaption>
                    <a href="/2026-09-23">
                      <time dateTime="2026-09-23">2026-09-23</time>の日記を見る
                    </a>
                  </figcaption>
                  <blockquote cite="/2026-09-23">
                    <div className="ProseMirror public-article-body">
                      <p>キーボードについて、別の日にも書いていた。</p>
                    </div>
                  </blockquote>
                </figure>
              </section>
            </section>
          </div>
        </PatternSection>

        <PatternSection title="Spacing and shape">
          <ul className="design-system__spacing">
            {SPACING_TOKENS.map(([step, size]) => (
              <li key={step}>
                <span
                  style={{ inlineSize: `var(--space-${step})` }}
                  aria-hidden="true"
                />
                <code>--space-{step}</code>
                <small>{size}</small>
              </li>
            ))}
          </ul>
          <section className="design-system__shapes" aria-label="角丸の見本">
            <span>Control</span>
            <span>Media</span>
            <span>Round</span>
          </section>
        </PatternSection>

        <PatternSection title="Controls and states">
          <div className="design-system__controls">
            <button type="button">通常</button>
            <button type="button" aria-pressed="true">
              選択中
            </button>
            <button type="button" className="is-focus-example">
              フォーカス
            </button>
            <button type="button" disabled>
              無効
            </button>
            <button type="button" aria-busy="true">
              読込中
            </button>
          </div>
        </PatternSection>

        <PatternSection title="Material panel">
          <div className="design-system__material-layout">
            <aside
              className="design-system__material-panel"
              aria-label="素材パネルの見本"
            >
              <header>
                <strong>写真</strong>
                <button type="button" aria-label="素材を更新">
                  更新
                </button>
              </header>
              <div className="design-system__photo-grid">
                <button
                  type="button"
                  aria-label="写真、8月28日21時40分、本文へ追加"
                >
                  <span aria-hidden="true" />
                </button>
                <button
                  type="button"
                  aria-label="写真、8月28日21時42分、本文へ追加"
                >
                  <span aria-hidden="true" />
                </button>
                <button
                  type="button"
                  aria-label="写真、8月28日21時45分、本文へ追加"
                >
                  <span aria-hidden="true" />
                </button>
              </div>
              <button className="design-system__bookmark" type="button">
                <strong>読み書きするためのインターフェース</strong>
                <span>example.com</span>
              </button>
              <p className="design-system__empty">素材はありません</p>
            </aside>
            <div
              className="design-system__vertical-tabs"
              role="tablist"
              aria-label="素材の種類"
            >
              <button type="button" role="tab" aria-selected="true">
                写真
              </button>
              <button type="button" role="tab" aria-selected="false">
                Raindrop
              </button>
            </div>
          </div>
        </PatternSection>
      </div>
    </article>
  );
}
