import { type JSONContent, Node } from "@tiptap/core";

export const ArticleImageTextGroup = Node.create({
  name: "articleImageTextGroup",
  group: "block",
  content: "block+",
  parseHTML: () => [{ tag: "div.article-image-text-group" }],
  renderHTML: () => ["div", { class: "article-image-text-group" }, 0],
  renderMarkdown: (node, helpers) =>
    helpers.renderChildren(node.content || [], "\n\n"),
});

export function groupPreviewImageText(document: JSONContent): JSONContent {
  const content: JSONContent[] = [];
  let group: JSONContent | undefined;
  for (const block of document.content || []) {
    if (
      block.type === "image" &&
      !block.marks?.some((mark) => mark.type === "link")
    ) {
      group = { type: "articleImageTextGroup", content: [block] };
      content.push(group);
    } else if (group && block.type === "paragraph") {
      group.content?.push(block);
    } else {
      group = undefined;
      content.push(block);
    }
  }
  return { ...document, content };
}
