export function installSpoilers(root: HTMLElement) {
  const click = (event: MouseEvent) => {
    if (!(event.target instanceof Element)) return;
    const spoiler = event.target.closest<HTMLElement>(".article-spoiler");
    if (!spoiler || !root.contains(spoiler)) return;
    const button = spoiler.querySelector<HTMLButtonElement>(
      ":scope > .article-spoiler__toggle",
    );
    const content = spoiler.querySelector<HTMLElement>(
      ":scope > .article-spoiler__content",
    );
    if (!button || !content) return;
    if (
      !button.contains(event.target) &&
      (spoiler.dataset.spoilerOpen !== "true" ||
        event.target.closest("a, button, video, audio, iframe, input"))
    )
      return;
    event.preventDefault();
    event.stopPropagation();
    const open = spoiler.dataset.spoilerOpen !== "true";
    if (!open) {
      for (const video of content.querySelectorAll("video")) video.pause();
      if (content.contains(document.activeElement)) button.focus();
    }
    spoiler.dataset.spoilerOpen = String(open);
    content.inert = !open;
    content.setAttribute("aria-hidden", String(!open));
    button.setAttribute("aria-expanded", String(open));
    button.setAttribute(
      "aria-label",
      open ? "スポイラーを隠す" : "スポイラーを表示",
    );
    button.textContent = open ? "隠す" : "クリックして表示";
  };
  root.addEventListener("click", click, true);
  return () => root.removeEventListener("click", click, true);
}
