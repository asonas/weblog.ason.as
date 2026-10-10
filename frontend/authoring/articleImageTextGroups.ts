export function groupPublicImageText(root: HTMLElement) {
  const parents = root.querySelectorAll<HTMLElement>(
    ".public-article-body > .article-piece, .public-article-body:not(:has(> .article-piece))",
  );
  for (const parent of parents) {
    let group: HTMLElement | undefined;
    for (const block of Array.from(parent.children)) {
      const image = block.querySelector(":scope > .article-image");
      const isImage =
        block.tagName === "P" &&
        image &&
        Array.from(block.childNodes).every(
          (node) =>
            node === image ||
            (node.nodeType === 3 && !node.textContent?.trim()),
        );
      if (isImage) {
        group = parent.ownerDocument.createElement("div");
        group.className = "article-image-text-group";
        block.before(group);
        group.append(block);
      } else if (
        block.tagName !== "P" ||
        block.querySelector(".article-image")
      ) {
        group = undefined;
      } else {
        group?.append(block);
      }
    }
  }
}
