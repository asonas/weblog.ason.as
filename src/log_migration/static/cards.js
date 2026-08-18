(() => {
  const explorer = document.querySelector(".card-explorer");
  if (!explorer) return;

  const canvas = explorer.querySelector(".card-canvas");
  const status = explorer.querySelector(".card-status");
  const dataUrl = explorer.dataset.cardDataUrl;
  const rangeDays = { "1d": 1, "7d": 7, "30d": 30, "100d": 100, all: null };
  const maxDepth = 3;
  let dataPromise;
  let edgeSet;

  const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (character) => {
    const entities = {
      "&": "&amp;",
      "<": "&lt;",
      ">": "&gt;",
      '"': "&quot;",
      "'": "&#39;",
    };
    return entities[character];
  });

  const edgeKey = (source, target) => `${source}\u0000${target}`;

  const loadData = () => {
    if (!dataPromise) {
      dataPromise = fetch(dataUrl, { headers: { Accept: "application/json" } }).then(
        (response) => {
          if (!response.ok) {
            throw new Error(`card data request failed: ${response.status}`);
          }
          return response.json();
        },
      );
    }
    return dataPromise;
  };

  const dateText = (createdAt) => (createdAt ? String(createdAt).slice(0, 10) : null);

  const compareStrings = (first, second) =>
    first < second ? -1 : first > second ? 1 : 0;

  const addDays = (dateValue, days) => {
    const date = new Date(`${dateValue}T00:00:00Z`);
    date.setUTCDate(date.getUTCDate() + days);
    return date.toISOString().slice(0, 10);
  };

  const rangeBounds = (root, range) => {
    const days = rangeDays[range];
    const rootDate = dateText(root.created_at);
    if (days === null || !rootDate) return [null, null];
    return [addDays(rootDate, -days), addDays(rootDate, days)];
  };

  const comparePosts = (first, second) => {
    const firstKey = [
      first.created_at || "9999-99-99T99:99:99+00:00",
      first.title,
      first.id,
    ].join("\u0000");
    const secondKey = [
      second.created_at || "9999-99-99T99:99:99+00:00",
      second.title,
      second.id,
    ].join("\u0000");
    return firstKey < secondKey ? -1 : firstKey > secondKey ? 1 : 0;
  };

  const relationLabel = (firstId, secondId) => {
    const outgoing = edgeSet.has(edgeKey(firstId, secondId));
    const incoming = edgeSet.has(edgeKey(secondId, firstId));
    if (incoming && outgoing) return "相互参照";
    if (outgoing) return "参照先";
    if (incoming) return "逆リンク";
    return "関連";
  };

  const visibleNodes = (data, rootId, range, depth) => {
    const postsById = new Map(data.posts.map((post) => [post.id, post]));
    const assetsById = new Map(data.assets.map((asset) => [asset.id, asset]));
    const adjacent = new Map();
    data.edges.forEach(({ source, target }) => {
      if (!adjacent.has(source)) adjacent.set(source, []);
      if (!adjacent.has(target)) adjacent.set(target, []);
      adjacent.get(source).push(target);
      adjacent.get(target).push(source);
    });
    adjacent.forEach((neighbors) => neighbors.sort());

    const root = postsById.get(rootId);
    if (!root) return { posts: [], assets: [], postsById, assetsById };
    const [startDate, endDate] = rangeBounds(root, range);
    const visited = new Set([rootId]);
    let frontier = [rootId];
    const found = [];
    for (let level = 0; level < depth; level += 1) {
      const nextFrontier = [];
      frontier.forEach((nodeId) => {
        (adjacent.get(nodeId) || []).forEach((neighborId) => {
          if (visited.has(neighborId)) return;
          visited.add(neighborId);
          nextFrontier.push(neighborId);
          const post = postsById.get(neighborId);
          const asset = assetsById.get(neighborId);
          if (asset || !startDate || !post?.created_at) {
            if (asset || !startDate || post?.created_at) found.push(neighborId);
            return;
          }
          const createdDate = dateText(post.created_at);
          if (createdDate >= startDate && createdDate <= endDate) found.push(neighborId);
        });
      });
      frontier = nextFrontier;
      if (!frontier.length) break;
    }

    return {
      assets: found
        .map((nodeId) => assetsById.get(nodeId))
        .filter(Boolean)
        .sort((first, second) => compareStrings(first.source_path, second.source_path)),
      posts: found
        .map((nodeId) => postsById.get(nodeId))
        .filter(Boolean)
        .sort(comparePosts),
      postsById,
      assetsById,
    };
  };

  const renderPost = (post, rootId) => {
    const isRoot = post.id === rootId;
    const id = escapeHtml(post.id);
    const title = escapeHtml(post.title);
    const createdAt = post.created_at ? escapeHtml(post.created_at) : "";
    const time = createdAt
      ? `<time datetime="${createdAt}">${createdAt.slice(0, 10)}</time>`
      : "";
    const toggle = isRoot
      ? ""
      : '<button type="button" data-card-toggle aria-expanded="false">展開</button>';
    const relation = isRoot ? "起点" : relationLabel(rootId, post.id);
    const cardClass = isRoot ? "card--root" : "card--compact";
    const bodyClass = isRoot ? "post-body" : "post-body post-body--compact";
    return `<article class="exploration-card post-card ${cardClass}" data-post-id="${id}">` +
      `<p class="card-relation">${relation}</p>` +
      `<header class="post-card__header"><h2><a href="/posts/${id}/">${title}</a></h2>` +
      `${time}${toggle}</header><div class="${bodyClass}">${post.body_html}</div></article>`;
  };

  const renderAsset = (asset, postsById, rootId) => {
    const references = asset.references
      .map((postId) => postsById.get(postId))
      .filter(Boolean);
    const visibleReferences = references.slice(0, 3);
    const remaining = references.length - visibleReferences.length;
    let links = visibleReferences.map((post) =>
      `<li><a href="/posts/${escapeHtml(post.id)}/">${escapeHtml(post.title)}</a></li>`
    ).join("");
    if (remaining) links += `<li>ほか${remaining}件</li>`;
    const referenceHtml = links ? `<ul>${links}</ul>` : "<p>参照元なし</p>";
    return `<article class="exploration-card asset-card card--compact" ` +
      `data-asset-id="${escapeHtml(asset.id)}">` +
      `<p class="card-relation">${relationLabel(rootId, asset.id)}</p>` +
      `<a href="/assets/${escapeHtml(asset.id)}/">` +
      `<span class="asset-card__kind">${escapeHtml(asset.kind)}</span>` +
      `<span class="asset-card__name">${escapeHtml(asset.source_path)}</span></a>` +
      `<div class="asset-card__references"><span>参照元</span>${referenceHtml}</div></article>`;
  };

  const bindToggles = () => {
    canvas.querySelectorAll("[data-card-toggle]").forEach((button) => {
      button.addEventListener("click", () => {
        const card = button.closest(".exploration-card");
        const body = card?.querySelector(".post-body");
        if (!card || !body) return;

        const compact = body.classList.toggle("post-body--compact");
        card.classList.toggle("card--compact", compact);
        button.textContent = compact ? "展開" : "折りたたむ";
        button.setAttribute("aria-expanded", String(!compact));
      });
    });
  };

  const updateControls = (range, depth) => {
    explorer.querySelectorAll("[data-range-option]").forEach((option) => {
      const selected = option.dataset.rangeOption === range;
      option.classList.toggle("is-selected", selected);
      if (selected) option.setAttribute("aria-current", "page");
      else option.removeAttribute("aria-current");
    });
    explorer.querySelectorAll("[data-depth-option]").forEach((option) => {
      const selected = Number(option.dataset.depthOption) === depth;
      option.classList.toggle("is-selected", selected);
      if (selected) option.setAttribute("aria-current", "page");
      else option.removeAttribute("aria-current");
    });
  };

  const updateUrl = (range, depth) => {
    if (!window.history?.replaceState) return;
    const url = new URL(window.location.href);
    url.searchParams.set("root", explorer.dataset.rootId);
    url.searchParams.set("range", range);
    url.searchParams.set("depth", String(depth));
    window.history.replaceState(null, "", `${url.pathname}?${url.searchParams}`);
  };

  const renderData = (data, range, depth) => {
    edgeSet = new Set(data.edges.map(({ source, target }) => edgeKey(source, target)));
    const rootId = explorer.dataset.rootId;
    const visible = visibleNodes(data, rootId, range, depth);
    const root = visible.postsById.get(rootId);
    if (!root) throw new Error(`root post not found: ${rootId}`);
    canvas.innerHTML = renderPost(root, rootId) +
      visible.posts.map((post) => renderPost(post, rootId)).join("") +
      visible.assets.map((asset) => renderAsset(asset, visible.postsById, rootId)).join("");
    bindToggles();
  };

  const applyState = async (range, depth, link) => {
    explorer.dataset.range = range;
    explorer.dataset.depth = String(depth);
    updateControls(range, depth);
    status.textContent = "カードデータを読み込んでいます。";
    try {
      const data = await loadData();
      renderData(data, range, depth);
      updateUrl(range, depth);
      status.textContent = "";
    } catch (error) {
      console.error(error);
      status.textContent = "カードデータを読み込めませんでした。";
      if (link) window.location.href = link.href;
    }
  };

  explorer.querySelectorAll("[data-range-option]").forEach((option) => {
    option.addEventListener("click", (event) => {
      event.preventDefault();
      const depth = Number(explorer.dataset.depth || 1);
      void applyState(option.dataset.rangeOption, depth, option);
    });
  });
  explorer.querySelectorAll("[data-depth-option]").forEach((option) => {
    option.addEventListener("click", (event) => {
      event.preventDefault();
      const range = explorer.dataset.range || "all";
      void applyState(range, Number(option.dataset.depthOption), option);
    });
  });

  bindToggles();
  const params = new URLSearchParams(window.location.search);
  const requestedRange = Object.prototype.hasOwnProperty.call(
    rangeDays,
    params.get("range"),
  ) ? params.get("range") : explorer.dataset.range || "all";
  const requestedDepth = Number(params.get("depth"));
  const depth = Number.isInteger(requestedDepth) && requestedDepth >= 0 && requestedDepth <= maxDepth
    ? requestedDepth
    : Number(explorer.dataset.depth || 1);
  if (requestedRange !== explorer.dataset.range || depth !== Number(explorer.dataset.depth)) {
    void applyState(requestedRange, depth);
  }
})();
