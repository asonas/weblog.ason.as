import type { ReactNode } from "react";

const COLOR_TOKENS = [
  ["Canvas", "--canvas"],
  ["Surface", "--surface"],
  ["Card", "--card-surface"],
  ["Ink", "--ink"],
  ["Muted ink", "--muted-ink"],
  ["Accent", "--accent"],
  ["Separator", "--separator"],
  ["Focus", "--focus-ring"],
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
          <div className="design-system__shapes" aria-label="角丸の見本">
            <span>Control</span>
            <span>Media</span>
            <span>Round</span>
          </div>
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
