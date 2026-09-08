import { Node as TiptapNode } from "@tiptap/core";
import type { NodeType } from "@tiptap/pm/model";
import {
  type EditorState,
  NodeSelection,
  Plugin,
  TextSelection,
} from "@tiptap/pm/state";

const SPEAKER_DECK_URL =
  /^https:\/\/speakerdeck\.com\/[A-Za-z0-9_-]+\/[A-Za-z0-9_-]+\/?(?:\?[^\s#]*)?(?:#[^\s]*)?$/;

export function loadSpeakerDeck(container: HTMLElement): () => void {
  const url = container.dataset.speakerdeckPlayer || "";
  if (!SPEAKER_DECK_URL.test(url)) return () => {};
  const controller = new AbortController();
  void fetch(`/api/embed?${new URLSearchParams({ url })}`, {
    signal: controller.signal,
  })
    .then(async (response) => {
      if (!response.ok) return;
      const metadata: unknown = await response.json();
      if (
        typeof metadata !== "object" ||
        metadata === null ||
        !("speakerdeck" in metadata)
      )
        return;
      const player = metadata.speakerdeck;
      if (
        typeof player !== "object" ||
        player === null ||
        !("src" in player) ||
        !("width" in player) ||
        !("height" in player)
      )
        return;
      if (
        controller.signal.aborted ||
        typeof player.src !== "string" ||
        !/^https:\/\/speakerdeck\.com\/player\/[a-f0-9]{32}$/.test(
          player.src,
        ) ||
        typeof player.width !== "number" ||
        !Number.isFinite(player.width) ||
        player.width <= 0 ||
        typeof player.height !== "number" ||
        !Number.isFinite(player.height) ||
        player.height <= 0
      )
        return;
      const iframe = document.createElement("iframe");
      iframe.src = player.src;
      iframe.title =
        "title" in metadata && typeof metadata.title === "string"
          ? metadata.title
          : "Speaker Deckスライド";
      iframe.loading = "lazy";
      iframe.allowFullscreen = true;
      iframe.style.aspectRatio = `${player.width} / ${player.height}`;
      container.prepend(iframe);
    })
    .catch(() => {
      // Keep the original link available when the embed cannot be fetched.
    });
  return () => controller.abort();
}

function replaceSpeakerDeckParagraphs(state: EditorState, type: NodeType) {
  const replacements: Array<{ from: number; to: number; url: string }> = [];
  state.doc.forEach((node, offset, index) => {
    const url = node.textContent.trim();
    if (
      index > 0 &&
      node.type.name === "paragraph" &&
      node.childCount === 1 &&
      node.firstChild?.isText &&
      !node.firstChild.marks.some((mark) => mark.type.name === "code") &&
      SPEAKER_DECK_URL.test(url)
    ) {
      replacements.push({ from: offset, to: offset + node.nodeSize, url });
    }
  });
  if (replacements.length === 0) return null;
  const transaction = state.tr;
  for (const { from, to, url } of replacements.reverse()) {
    transaction.replaceWith(from, to, type.create({ url }));
  }
  return transaction;
}

export const SpeakerDeckPlayer = TiptapNode.create({
  name: "speakerdeckPlayer",
  group: "block",
  atom: true,
  selectable: true,

  addAttributes() {
    return { url: { default: "" } };
  },

  parseHTML() {
    return [
      {
        tag: "div[data-speakerdeck-player]",
        getAttrs: (element) => ({
          url: (element as HTMLElement).dataset.speakerdeckPlayer || "",
        }),
      },
    ];
  },

  renderHTML({ node }) {
    const url = node.attrs.url as string;
    return [
      "div",
      { class: "speakerdeck-player", "data-speakerdeck-player": url },
      ["a", { href: url, target: "_blank", rel: "noreferrer" }, url],
    ];
  },

  addNodeView() {
    return ({ node }) => {
      const dom = document.createElement("div");
      dom.className = "speakerdeck-player";
      dom.dataset.speakerdeckPlayer = node.attrs.url;
      const link = document.createElement("a");
      link.href = node.attrs.url;
      link.textContent = node.attrs.url;
      link.target = "_blank";
      link.rel = "noreferrer";
      dom.append(link);
      const cleanup = loadSpeakerDeck(dom);
      return { dom, ignoreMutation: () => true, destroy: cleanup };
    };
  },

  renderMarkdown: (node) => node.attrs?.url || "",

  onCreate() {
    const transaction = replaceSpeakerDeckParagraphs(
      this.editor.state,
      this.type,
    );
    if (transaction) this.editor.view.dispatch(transaction);
  },

  addProseMirrorPlugins() {
    const editor = this.editor;
    return [
      new Plugin({
        appendTransaction: (transactions, oldState, state) => {
          if (
            transactions.some((transaction) =>
              transaction.getMeta("speakerdeckRawEditing"),
            )
          )
            return null;
          const selection = state.selection;
          if (
            editor.isEditable &&
            transactions.some((transaction) => transaction.selectionSet) &&
            selection instanceof NodeSelection &&
            selection.node.type === this.type
          ) {
            const url = selection.node.attrs.url;
            const paragraph = state.schema.nodes.paragraph.create(
              null,
              state.schema.text(url),
            );
            const transaction = state.tr.replaceWith(
              selection.from,
              selection.to,
              paragraph,
            );
            return transaction
              .setSelection(
                TextSelection.create(
                  transaction.doc,
                  selection.from +
                    (oldState.selection.to <= selection.from
                      ? 1
                      : url.length + 1),
                ),
              )
              .setMeta("speakerdeckRawEditing", true);
          }
          return replaceSpeakerDeckParagraphs(state, this.type);
        },
      }),
    ];
  },
});
