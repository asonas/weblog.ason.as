export type ScrollAnchor = {
  element: Element;
  top: number;
};

export function captureScrollAnchor(container: Element): ScrollAnchor | null {
  const candidates = Array.from(container.querySelectorAll(".atlas-entry"))
    .map((element) => ({ element, rect: element.getBoundingClientRect() }))
    .filter(({ rect }) => rect.bottom > 0);
  const crossingViewportTop = candidates
    .filter(({ rect }) => rect.top <= 0)
    .sort((left, right) => right.rect.top - left.rect.top)[0];
  const candidate =
    crossingViewportTop ||
    candidates.sort((left, right) => left.rect.top - right.rect.top)[0];

  return candidate
    ? { element: candidate.element, top: candidate.rect.top }
    : null;
}

export function restoreScrollAnchor(
  anchor: ScrollAnchor | null,
  scrollBy: (top: number) => void = (top) => window.scrollBy({ top }),
) {
  if (!anchor?.element.isConnected) return;

  const movement = anchor.element.getBoundingClientRect().top - anchor.top;
  if (movement !== 0) scrollBy(movement);
}
