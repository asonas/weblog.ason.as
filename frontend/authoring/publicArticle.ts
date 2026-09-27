import { hydrateEmbedCard } from "./EmbedCard";
import { installMobileArticleSheet } from "./mobileArticleSheet";
import { hydrateXPost } from "./XPost";

function watchMedia(
  media: HTMLImageElement | HTMLIFrameElement | HTMLVideoElement,
  container: HTMLElement,
) {
  let timeout: number | undefined;
  const finish = (failed: boolean) => {
    container.dataset.mediaState = failed ? "failed" : "ready";
    window.clearTimeout(timeout);
  };
  media.addEventListener(
    media instanceof HTMLVideoElement ? "loadeddata" : "load",
    () => finish(false),
    { once: true },
  );
  media.addEventListener("error", () => finish(true), { once: true });
  if (media instanceof HTMLImageElement && media.complete) {
    finish(media.naturalWidth === 0);
  }
  if (media instanceof HTMLVideoElement && media.readyState >= 2) finish(false);
  return () => {
    if (!container.dataset.mediaState)
      timeout = window.setTimeout(() => finish(true), 15000);
  };
}

async function loadSpeakerDeck(container: HTMLElement) {
  const url = container.dataset.speakerdeckPlayer;
  if (!url) return;
  try {
    const response = await fetch(`/api/embed?${new URLSearchParams({ url })}`, {
      signal: AbortSignal.timeout(12000),
    });
    if (!response.ok) throw new Error("Embed unavailable");
    const metadata: unknown = await response.json();
    if (
      !metadata ||
      typeof metadata !== "object" ||
      !("speakerdeck" in metadata)
    )
      throw new Error("Invalid embed");
    const player = metadata.speakerdeck;
    if (
      !player ||
      typeof player !== "object" ||
      !("src" in player) ||
      typeof player.src !== "string" ||
      !/^https:\/\/speakerdeck\.com\/player\/[a-f0-9]{32}$/.test(player.src)
    )
      throw new Error("Invalid player");
    const frame = document.createElement("iframe");
    frame.title = "Speaker Deckスライド";
    frame.allowFullscreen = true;
    frame.referrerPolicy = "strict-origin-when-cross-origin";
    const startWaiting = watchMedia(frame, container);
    frame.src = player.src;
    container.prepend(frame);
    startWaiting();
  } catch {
    container.dataset.mediaState = "failed";
  }
}

export async function enhancePublicArticleEditing(
  article: HTMLElement,
  fetcher: typeof fetch = fetch,
) {
  const editingHref = article.dataset.editingHref;
  const actions = document.querySelector<HTMLElement>(
    ".site-header .header-actions",
  );
  if (!editingHref || !actions) return;

  try {
    const response = await fetcher("/api/auth/session", {
      headers: { Accept: "application/json" },
    });
    if (!response.ok) return;
    const auth: unknown = await response.json();
    if (
      typeof auth !== "object" ||
      auth === null ||
      !("can_edit" in auth) ||
      auth.can_edit !== true
    )
      return;

    const edit = document.createElement("a");
    edit.className =
      "header-action header-action--view-mode public-authoring-action";
    edit.href = editingHref;
    edit.setAttribute("aria-label", "この記事を編集");
    edit.title = "この記事を編集";
    // Regen Icons edit, MIT: ./regen-icons-LICENSE.txt
    edit.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 18.4L4 16.83A2 2 0 0 1 4.59 15.41L14.59 5.41A2 2 0 0 1 17.41 5.41L18.59 6.59A2 2 0 0 1 18.59 9.41L8.59 19.41A2 2 0 0 1 7.17 20L5.6 20A1.6 1.6 0 0 1 4 18.4ZM13 7L17 11"/></svg>';
    actions.append(edit);
  } catch {
    return;
  }
}

function enhanceArticleImages(root: HTMLElement) {
  const images = root.querySelectorAll<HTMLImageElement>(
    ".article-image > img",
  );
  if (images.length === 0) return;

  const header = document.querySelector<HTMLElement>(".site-header");
  let headerHeight = 0;
  let availableHeight = 0;
  const updateViewport = () => {
    headerHeight = header?.getBoundingClientRect().height ?? 0;
    availableHeight = Math.max(0, window.innerHeight - headerHeight);
    root.style.setProperty(
      "--expanded-image-height",
      `${availableHeight * 0.75}px`,
    );
  };
  updateViewport();
  window.addEventListener("resize", updateViewport);
  if (header && typeof ResizeObserver !== "undefined")
    new ResizeObserver(updateViewport).observe(header);

  window.addEventListener("keydown", (event) => {
    if (
      event.key !== "Escape" ||
      event.defaultPrevented ||
      document.querySelector("dialog[open]")
    )
      return;
    for (const button of root.querySelectorAll<HTMLButtonElement>(
      ".article-image--expanded .article-image__zoom",
    ))
      button.click();
  });

  for (const image of images) {
    const container = image.parentElement;
    if (!container || container.closest("a")) continue;
    const updateSourceWidth = () => {
      const width = image.naturalWidth || Number(image.getAttribute("width"));
      const height =
        image.naturalHeight || Number(image.getAttribute("height"));
      if (width > 0)
        container.style.setProperty("--image-source-width", `${width}px`);
      if (width > 0 && height > 0)
        container.style.setProperty("--image-ratio", String(width / height));
    };
    image.addEventListener("load", updateSourceWidth);
    updateSourceWidth();
    const label = image.alt ? `${image.alt}を` : "画像を";
    const button = document.createElement("button");
    button.type = "button";
    button.className = "article-image__zoom";
    button.setAttribute("aria-label", `${label}拡大`);
    button.setAttribute("aria-expanded", "false");
    image.replaceWith(button);
    button.append(image);
    button.addEventListener("click", () => {
      const expanded = !container.classList.contains("article-image--expanded");
      if (expanded && container.dataset.mediaState === "failed") return;
      container.classList.toggle("article-image--expanded", expanded);
      button.setAttribute("aria-expanded", String(expanded));
      button.setAttribute(
        "aria-label",
        `${label}${expanded ? "縮小" : "拡大"}`,
      );
      if (expanded) {
        updateViewport();
        const bounds = image.getBoundingClientRect();
        window.scrollTo({
          top:
            window.scrollY +
            bounds.top -
            headerHeight -
            (availableHeight - bounds.height) / 2,
          behavior: "instant",
        });
      }
    });
  }
}

export function enhancePublicArticle(root: HTMLElement) {
  window.addEventListener("message", (event) => {
    if (event.origin !== "https://embed.bsky.app") return;
    const { id, height } = event.data ?? {};
    if (
      typeof id !== "string" ||
      typeof height !== "number" ||
      !Number.isFinite(height) ||
      height <= 0
    )
      return;
    const iframe = Array.from(
      root.querySelectorAll<HTMLIFrameElement>("iframe[data-bluesky-id]"),
    ).find((candidate) => candidate.dataset.blueskyId === id);
    if (iframe && event.source === iframe.contentWindow)
      iframe.style.height = `${height}px`;
  });
  const pending = new Map<HTMLElement, () => void>();
  for (const media of root.querySelectorAll<
    HTMLImageElement | HTMLIFrameElement | HTMLVideoElement
  >(
    ".article-image > img, .article-reading-header--covered > img, iframe, .article-video > video",
  )) {
    if (media.parentElement)
      pending.set(media.parentElement, watchMedia(media, media.parentElement));
  }
  enhanceArticleImages(root);
  for (const embed of root.querySelectorAll<HTMLElement>(
    ".speakerdeck-player",
  )) {
    pending.set(embed, () => {
      void loadSpeakerDeck(embed);
    });
  }
  for (const embed of root.querySelectorAll<HTMLElement>(
    ".embed-card[data-embed-url]",
  )) {
    pending.set(embed, () => {
      void hydrateEmbedCard(embed);
    });
  }
  for (const post of root.querySelectorAll<HTMLElement>(
    ".x-post[data-x-post-id]",
  )) {
    pending.set(post, () => {
      void hydrateXPost(post);
    });
  }
  if (!("IntersectionObserver" in window)) {
    for (const start of pending.values()) start();
    return;
  }
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting || !(entry.target instanceof HTMLElement))
          continue;
        observer.unobserve(entry.target);
        pending.get(entry.target)?.();
        pending.delete(entry.target);
      }
    },
    { rootMargin: "300px" },
  );
  for (const target of pending.keys()) observer.observe(target);
}

const article = document.querySelector<HTMLElement>("[data-public-article]");
if (article) {
  enhancePublicArticle(article);
  void enhancePublicArticleEditing(article);
  installMobileArticleSheet();
}

if (document.querySelector("[data-public-universe]")) {
  const updateHeader = () => {
    document.documentElement.dataset.headerScrolled = String(
      window.scrollY > 8,
    );
  };
  updateHeader();
  window.addEventListener("scroll", updateHeader, { passive: true });
  void import("./PublicUniverse").then(({ mountPublicReader }) =>
    mountPublicReader(),
  );
}
