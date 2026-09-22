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
    edit.href = "/authoring/articles";
    edit.setAttribute("aria-label", "記事管理");
    edit.title = "記事管理";
    // Regen Icons file-text, MIT: ./regen-icons-LICENSE.txt
    edit.innerHTML =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12.38 3L6.5 3A1.5 1.5 0 0 0 5 4.5L5 19.5A1.5 1.5 0 0 0 6.5 21L17.5 21A1.5 1.5 0 0 0 19 19.5L19 9.62A1.5 1.5 0 0 0 18.56 8.56L13.44 3.44A1.5 1.5 0 0 0 12.38 3ZM13 4L13 8A1 1 0 0 0 14 9L18 9M9 13L15 13M9 17L15 17"/></svg>';
    actions.append(edit);
  } catch {
    return;
  }
}

export function enhancePublicArticle(root: HTMLElement) {
  const pending = new Map<HTMLElement, () => void>();
  for (const media of root.querySelectorAll<
    HTMLImageElement | HTMLIFrameElement | HTMLVideoElement
  >(
    ".article-image > img, .article-reading-header--covered > img, iframe, .article-video > video",
  )) {
    if (media.parentElement)
      pending.set(media.parentElement, watchMedia(media, media.parentElement));
  }
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
