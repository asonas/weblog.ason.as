export function installMobileArticleSheet() {
  if (!window.matchMedia) return () => {};
  const mobile = window.matchMedia("(max-width: 767px)");
  const dialog = document.createElement("dialog");
  if (!dialog.showModal) return () => {};
  dialog.className = "article-sheet";
  dialog.setAttribute("aria-labelledby", "article-sheet-title");
  const toolbar = document.createElement("div");
  toolbar.className = "article-sheet__toolbar";
  const title = document.createElement("h2");
  title.id = "article-sheet-title";
  const close = document.createElement("button");
  close.type = "button";
  close.setAttribute("aria-label", "閉じる");
  close.innerHTML =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m7 7 10 10M17 7 7 17" /></svg>';
  const permalink = document.createElement("a");
  permalink.textContent = "記事を読む";
  const footer = document.createElement("div");
  footer.className = "article-sheet__footer";
  footer.append(permalink);
  toolbar.append(title, close);
  const status = document.createElement("p");
  status.className = "article-sheet__status";
  status.setAttribute("role", "status");
  const content = document.createElement("div");
  content.className = "article-sheet__content";
  content.append(status);
  dialog.append(toolbar, content, footer);
  document.body.append(dialog);
  let request: AbortController | undefined;
  let trigger: HTMLElement | null = null;
  let scrollY = 0;
  let bodyStyle = "";
  let currentUrl = window.location.href;

  const restore = () => {
    request?.abort();
    content.replaceChildren(status);
    document.body.style.cssText = bodyStyle;
    window.scrollTo(0, scrollY);
    trigger?.focus({ preventScroll: true });
    currentUrl = window.location.href;
  };
  dialog.addEventListener("close", restore);
  close.addEventListener("click", () => dialog.close());
  dialog.addEventListener("click", (event) => {
    if (event.target !== dialog) return;
    const bounds = dialog.getBoundingClientRect();
    if (
      event.clientY < bounds.top ||
      event.clientX < bounds.left ||
      event.clientX > bounds.right
    )
      dialog.close();
  });
  const resize = () => {
    if (!mobile.matches && dialog.open) dialog.close();
  };
  mobile.addEventListener("change", resize);

  const show = async (url: URL, link: HTMLElement) => {
    request?.abort();
    const controller = new AbortController();
    request = controller;
    currentUrl = url.href;
    permalink.href = url.href;
    title.textContent = link.textContent?.trim() || "記事のプレビュー";
    content.replaceChildren(status);
    status.textContent = "記事を読み込んでいます…";
    content.setAttribute("aria-busy", "true");
    if (!dialog.open) {
      trigger = link;
      scrollY = window.scrollY;
      bodyStyle = document.body.style.cssText;
      Object.assign(document.body.style, {
        position: "fixed",
        top: `-${scrollY}px`,
        width: "100%",
      });
      dialog.showModal();
    }
    close.focus({ preventScroll: true });
    try {
      const response = await fetch(url.href, {
        headers: { Accept: "text/html" },
        signal: AbortSignal.any([
          controller.signal,
          AbortSignal.timeout(15000),
        ]),
      });
      if (!response.ok) throw new Error("Article unavailable");
      const parsed = new DOMParser().parseFromString(
        await response.text(),
        "text/html",
      );
      const article = parsed.querySelector<HTMLElement>(
        "[data-public-article]",
      );
      if (!article) throw new Error("Article unavailable");
      if (controller.signal.aborted) return;
      title.textContent =
        article.querySelector("h1")?.textContent?.trim() || title.textContent;
      const body = article.querySelector(".e-content");
      const excerpt = document.createElement("p");
      excerpt.className = "article-sheet__excerpt";
      if (body) {
        const textBody = body.cloneNode(true) as HTMLElement;
        textBody
          .querySelectorAll(
            "script, style, iframe, video, audio, figure, .speakerdeck-player, .youtube-player, .bluesky-player",
          )
          .forEach((element) => {
            element.remove();
          });
        textBody
          .querySelectorAll("p, li, h2, h3, pre, br")
          .forEach((element) => {
            element.append(" ");
          });
        excerpt.textContent =
          textBody.textContent?.replace(/\s+/g, " ").trim() ||
          "本文のテキストはありません。";
      } else {
        excerpt.textContent = "本文のテキストはありません。";
      }
      content.append(excerpt);
      const links = new Map<string, { label: string; url: URL }>();
      for (const anchor of body?.querySelectorAll<HTMLAnchorElement>(
        "a[href]",
      ) || []) {
        const href = anchor.getAttribute("href") || "";
        const base = response.url || url.href;
        if (!URL.canParse(href, base)) continue;
        const destination = new URL(href, base);
        if (
          !["http:", "https:"].includes(destination.protocol) ||
          anchor.hasAttribute("download") ||
          (destination.origin === url.origin &&
            destination.pathname === url.pathname)
        )
          continue;
        if (!links.has(destination.href))
          links.set(destination.href, {
            label: anchor.textContent?.trim() || destination.hostname,
            url: destination,
          });
      }
      const references: unknown = JSON.parse(
        article.querySelector<HTMLElement>("[data-public-universe]")?.dataset
          .publicUniverse || "{}",
      );
      if (
        references &&
        typeof references === "object" &&
        "urls" in references &&
        Array.isArray(references.urls)
      ) {
        for (const href of references.urls) {
          if (typeof href !== "string" || !URL.canParse(href)) continue;
          const destination = new URL(href);
          if (
            !["http:", "https:"].includes(destination.protocol) ||
            links.has(destination.href)
          )
            continue;
          links.set(destination.href, {
            label:
              destination.hostname +
              (destination.pathname === "/" ? "" : destination.pathname),
            url: destination,
          });
        }
      }
      if (links.size) {
        const nav = document.createElement("nav");
        nav.className = "article-sheet__links";
        nav.setAttribute("aria-label", "この記事のリンク");
        const label = document.createElement("p");
        label.textContent = `この記事のリンク · ${links.size}件`;
        const list = document.createElement("div");
        for (const { label: text, url: destination } of Array.from(
          links.values(),
        ).slice(0, 4)) {
          const item = document.createElement("a");
          item.href = destination.href;
          const name = document.createElement("span");
          name.textContent = text;
          item.append(name);
          if (destination.origin !== window.location.origin) {
            const host = document.createElement("small");
            host.textContent = destination.hostname;
            item.append(host);
          }
          list.append(item);
        }
        nav.append(label, list);
        content.append(nav);
      }
      status.textContent = "";
      content.scrollTop = 0;
    } catch {
      if (!controller.signal.aborted)
        status.textContent =
          "記事を読み込めませんでした。「記事を読む」から確認できます。";
    } finally {
      if (!controller.signal.aborted) content.removeAttribute("aria-busy");
    }
  };

  const onClick = (event: MouseEvent) => {
    if (
      !mobile.matches ||
      event.defaultPrevented ||
      event.button !== 0 ||
      event.metaKey ||
      event.ctrlKey ||
      event.shiftKey ||
      event.altKey
    )
      return;
    if (!(event.target instanceof Element)) return;
    const link = event.target.closest<HTMLAnchorElement>("a[href]");
    if (
      !link ||
      link === permalink ||
      !link.closest(".article-workspace--reading, .article-sheet") ||
      link.closest('[contenteditable="true"]') ||
      link.hasAttribute("download") ||
      (link.target && link.target !== "_self")
    )
      return;
    const url = new URL(link.href);
    const source = new URL(
      dialog.contains(link) ? currentUrl : window.location.href,
    );
    if (
      url.origin !== window.location.origin ||
      url.search ||
      (url.pathname === source.pathname && url.hash)
    )
      return;
    const route = url.pathname.slice(1).replace(/\/$/, "");
    if (
      !route ||
      route.includes("/") ||
      [
        "search",
        "api",
        "editor",
        "assets",
        "feed.xml",
        "index.html",
        "public.html",
        "404.html",
      ].includes(route)
    )
      return;
    event.preventDefault();
    void show(url, link);
  };
  document.addEventListener("click", onClick);
  return () => {
    if (dialog.open) {
      dialog.removeEventListener("close", restore);
      dialog.close();
      restore();
    }
    request?.abort();
    document.removeEventListener("click", onClick);
    mobile.removeEventListener("change", resize);
    dialog.remove();
  };
}
