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

export function enhancePublicArticle(root: HTMLElement) {
  const pending = new Map<HTMLElement, () => void>();
  for (const media of root.querySelectorAll<
    HTMLImageElement | HTMLIFrameElement | HTMLVideoElement
  >(
    ".article-image > img, .page-header--covered > img, iframe, .article-video > video",
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
if (article) enhancePublicArticle(article);
