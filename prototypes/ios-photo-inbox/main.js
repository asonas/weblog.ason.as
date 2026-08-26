const photos = [
  { id: 1, tone: "ochre", time: "18:42", label: "夕方の机" },
  { id: 2, tone: "blue", time: "17:08", label: "川沿い" },
  { id: 3, tone: "green", time: "12:31", label: "昼食" },
  { id: 4, tone: "rose", time: "09:14", label: "駅のホーム" },
  { id: 5, tone: "slate", time: "08:56", label: "朝の空" },
  { id: 6, tone: "sand", time: "昨日", label: "読みかけの本" }
];

const icon = (name) => {
  const paths = {
    plus: '<path d="M12 5v14M5 12h14"/>',
    check: '<path d="m5 12 4 4L19 6"/>',
    arrow: '<path d="m9 18 6-6-6-6"/>',
    retry: '<path d="M20 11a8 8 0 1 0-2.34 5.66M20 4v7h-7"/>',
    cloud: '<path d="M16 16l-4-4-4 4M12 12v9M20.4 17.5A5 5 0 0 0 18 8.2 7 7 0 0 0 4.3 10.8 4 4 0 0 0 5 18h2"/>'
  };
  return `<svg aria-hidden="true" viewBox="0 0 24 24">${paths[name]}</svg>`;
};

const photo = (item, selectable = false) => `
  <button class="photo photo--${item.tone}${selectable ? " is-selectable" : ""}" type="button" aria-label="${item.label}、${item.time}" data-photo="${item.id}">
    <span class="photo__texture"></span>
    <span class="photo__time">${item.time}</span>
    ${selectable ? '<span class="photo__check">' + icon("check") + "</span>" : ""}
  </button>`;

const shell = (body, title = "写真インボックス", minimal = false) => `
  <section class="phone${minimal ? " phone--minimal" : ""}" aria-label="${title}">
    <header class="nav-bar">
      ${minimal ? "" : `<div><p class="eyebrow">weblog.ason.as</p><h1>${title}</h1></div>`}
      <button class="avatar" type="button" aria-label="アカウント設定">A</button>
    </header>
    ${body}
    <div class="home-indicator" aria-hidden="true"></div>
  </section>`;

const variants = {
  a: () => shell(`
    <div class="screen screen--selection">
      <div class="photo-grid photo-grid--large">${photos.slice(0, 5).map((item) => photo(item, true)).join("")}</div>
      <div class="selection-dock">
        <span class="selection-count" aria-live="polite"><strong data-count>5</strong>枚</span>
        <button class="primary-action" type="button" data-send>${icon("cloud")}すべて送る</button>
      </div>
    </div>`, "今日の写真", true),
  b: () => shell(`
    <div class="screen screen--queue">
      <div class="status-hero"><span class="status-hero__icon">${icon("cloud")}</span><div><strong>転送は自動で続きます</strong><p>アプリを閉じても問題ありません</p></div></div>
      <section class="queue-section"><div class="section-title"><h2>転送中</h2><span>2件</span></div>
        <article class="queue-card"><div class="thumb thumb--blue"></div><div class="queue-copy"><strong>川沿い</strong><span>1.8 MB / 3.2 MB</span><div class="progress"><i style="width:56%"></i></div></div><span class="percent">56%</span></article>
        <article class="queue-card"><div class="thumb thumb--green"></div><div class="queue-copy"><strong>昼食</strong><span>待機中</span></div><span class="queue-state">次</span></article>
      </section>
      <section class="queue-section"><div class="section-title"><h2>確認が必要</h2><span>1件</span></div>
        <article class="queue-card queue-card--error"><div class="thumb thumb--rose"></div><div class="queue-copy"><strong>駅のホーム</strong><span>ネットワークに接続できませんでした</span></div><button class="icon-action" type="button" aria-label="再試行">${icon("retry")}</button></article>
      </section>
      <section class="queue-section"><div class="section-title"><h2>完了</h2><span>今日 3件</span></div>
        <article class="queue-card"><div class="thumb thumb--ochre"></div><div class="queue-copy"><strong>夕方の机</strong><span>18:43 に転送済み</span></div><span class="done">${icon("check")}</span></article>
      </section>
      <button class="floating-add" type="button">${icon("plus")}写真を追加</button>
    </div>`, "転送状況"),
  c: () => shell(`
    <div class="screen screen--daily">
      <div class="date-card"><p>2026年8月26日 水曜日</p><strong>今日の記録</strong><span>日記に使えそうな写真をまとめておけます。</span></div>
      <section><div class="section-title"><h2>今日</h2><button type="button" class="text-action">すべて選ぶ</button></div>
        <div class="photo-strip">${photos.slice(0, 5).map((item) => photo(item, true)).join("")}</div>
      </section>
      <section class="inbox-card"><div><span class="inbox-mark">W</span><p><strong>インボックス</strong><span>今日追加した写真</span></p></div><strong>3</strong></section>
      <section class="recent"><div class="section-title"><h2>昨日から</h2><span>未送信 1件</span></div>${photo(photos[5])}<div class="recent-copy"><strong>読みかけの本</strong><span>昨日 22:18</span></div></section>
      <button class="primary-action" type="button" data-send disabled><span data-count>0</span>枚をインボックスに追加${icon("arrow")}</button>
      <p class="footnote">写真は7日間、編集画面から利用できます</p>
    </div>`)
};

const getVariant = () => {
  const value = new URLSearchParams(location.search).get("variant")?.toLowerCase();
  return Object.hasOwn(variants, value) ? value : "a";
};

const render = (variant) => {
  document.querySelector("#app").innerHTML = variants[variant]();
  document.body.dataset.variant = variant;
  document.querySelectorAll("[data-variant]").forEach((button) => button.classList.toggle("is-active", button.dataset.variant === variant));
  const selected = new Set(variant === "a" ? photos.slice(0, 5).map(({ id }) => String(id)) : []);
  document.querySelectorAll("[data-photo]").forEach((button) => button.addEventListener("click", () => {
    const id = button.dataset.photo;
    selected.has(id) ? selected.delete(id) : selected.add(id);
    button.classList.toggle("is-selected", selected.has(id));
    document.querySelectorAll("[data-count]").forEach((count) => { count.textContent = selected.size; });
    const send = document.querySelector("[data-send]");
    if (send) send.disabled = selected.size === 0;
  }));
  if (variant === "a") {
    document.querySelectorAll("[data-photo]").forEach((button) => button.classList.add("is-selected"));
  }
};

const selectVariant = (variant) => {
  const url = new URL(location.href);
  url.searchParams.set("variant", variant);
  history.replaceState({}, "", url);
  render(variant);
};

document.querySelectorAll("[data-variant]").forEach((button) => button.addEventListener("click", () => selectVariant(button.dataset.variant)));
window.addEventListener("keydown", (event) => {
  if (!["ArrowLeft", "ArrowRight"].includes(event.key)) return;
  const keys = Object.keys(variants);
  const current = keys.indexOf(getVariant());
  selectVariant(keys[(current + (event.key === "ArrowRight" ? 1 : -1) + keys.length) % keys.length]);
});
render(getVariant());
