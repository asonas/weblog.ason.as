const items = [
  { id: "p1", type: "写真", time: "18:42", title: "夕方の机", color: "ochre", insert: "![夕方の机](/assets/2026/08/desk.jpg)" },
  { id: "b1", type: "Bluesky", time: "17:06", title: "今日の実装について書いた投稿", color: "sky", insert: '<div class="bluesky-embed">Bluesky post</div>' },
  { id: "r1", type: "Raindrop", time: "15:20", title: "Designing for calm technology", color: "paper", insert: "https://example.com/calm-technology" },
  { id: "c1", type: "c4p", time: "12:10", title: "ep. 48 日記と写真", color: "audio", insert: "[c4p:https://c4p.ason.as/episodes/48]" },
  { id: "p2", type: "写真", time: "09:14", title: "駅のホーム", color: "rose", insert: "![駅のホーム](/assets/2026/08/station.jpg)" }
];
const itemHtml = (item) => `<article class="item" draggable="true" data-id="${item.id}"><div class="thumb ${item.color}"><span>${item.type.slice(0,1)}</span></div><div class="copy"><small>${item.time} · ${item.type}</small><strong>${item.title}</strong></div><button data-insert="${item.id}" aria-label="${item.title}を挿入">＋</button></article>`;
const panel = (variant) => `<aside class="inbox inbox--${variant}" aria-label="コンテンツインボックス"><header><strong>Inbox</strong><span><b data-count>${items.length}</b>件</span></header><div class="filters"><button class="active">すべて</button><button>写真</button><button>リンク</button><button>音声</button></div><div class="date">今日</div><div class="items">${items.map(itemHtml).join("")}</div><footer>直近7日間の未使用素材</footer></aside>`;
const render = (variant) => {
  document.querySelector("#app").innerHTML = `<div class="page"><header class="site"><b>weblog.ason.as</b><span>2026年8月26日</span></header><section class="editor"><button class="inbox-tab" aria-expanded="true"><span></span>Inbox <b data-badge>${items.length}</b></button><div class="paper"><h1>2026年8月26日</h1><div class="prose" contenteditable="true" data-editor><p>今日は写真インボックスの操作を考えた。</p><p class="caret">ここに素材を追加できます</p></div></div>${panel(variant)}</section></div>`;
  document.body.dataset.variant = variant;
  document.querySelectorAll("[data-variant]").forEach(b => b.classList.toggle("active", b.dataset.variant === variant));
  const consume = (id) => {
    const item = items.find(entry => entry.id === id);
    const card = document.querySelector(`[data-id="${id}"]`);
    if (!item || !card) return;
    document.querySelector("[data-editor]").insertAdjacentHTML("beforeend", `<p class="inserted">${item.insert}</p>`);
    card.classList.add("used"); setTimeout(() => { card.remove(); updateCount(); }, 260);
  };
  const updateCount = () => { const count = document.querySelectorAll(".item:not(.used)").length; document.querySelectorAll("[data-count],[data-badge]").forEach(n => n.textContent = count); };
  document.querySelectorAll("[data-insert]").forEach(b => b.addEventListener("click", () => consume(b.dataset.insert)));
  document.querySelectorAll(".item").forEach(card => card.addEventListener("dragstart", e => e.dataTransfer.setData("text/item-id", card.dataset.id)));
  const editor = document.querySelector("[data-editor]"); editor.addEventListener("dragover", e => { e.preventDefault(); editor.classList.add("drop"); }); editor.addEventListener("dragleave", () => editor.classList.remove("drop")); editor.addEventListener("drop", e => { e.preventDefault(); editor.classList.remove("drop"); consume(e.dataTransfer.getData("text/item-id")); });
  document.querySelector(".inbox-tab").addEventListener("click", e => { document.querySelector(".inbox").classList.toggle("closed"); e.currentTarget.setAttribute("aria-expanded", !document.querySelector(".inbox").classList.contains("closed")); });
};
const current = () => new URLSearchParams(location.search).get("variant") || "a";
const choose = variant => { const url = new URL(location); url.searchParams.set("variant", variant); history.replaceState({}, "", url); render(variant); };
document.querySelectorAll("[data-variant]").forEach(b => b.addEventListener("click", () => choose(b.dataset.variant)));
window.addEventListener("keydown", e => { if (!['ArrowLeft','ArrowRight'].includes(e.key)) return; const all=['a','b','c'], i=all.indexOf(current()); choose(all[(i+(e.key==='ArrowRight'?1:2))%3]); });
render(current());
