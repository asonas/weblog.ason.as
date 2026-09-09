import Image from "@tiptap/extension-image";
import { DOMSerializer, type ResolvedPos } from "@tiptap/pm/model";
import { Plugin, Selection, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet, type EditorView } from "@tiptap/pm/view";

export const SelectableImage = Image.extend({
  addNodeView() {
    return ({ node, editor, decorations }) => {
      const dom = document.createElement("div");
      dom.className = "selectable-image";
      dom.contentEditable = "false";
      const serializer = DOMSerializer.fromSchema(editor.schema);
      let image = serializer.serializeNode(node);
      const markdown = document.createElement("span");
      markdown.className = "selected-image-markdown";
      dom.append(image, markdown);
      let currentNode = node;
      let showsMarkdown = decorations.some((item) => item.spec.imageMarkdown);
      const render = () => {
        markdown.textContent = editor.storage.markdown.manager.serialize(
          currentNode.toJSON(),
        );
        markdown.hidden = !showsMarkdown;
        dom.classList.toggle("selectable-image--selected", showsMarkdown);
      };
      render();
      return {
        dom,
        update(nextNode, nextDecorations) {
          if (nextNode.type !== node.type) return false;
          if (!currentNode.eq(nextNode)) {
            const nextImage = serializer.serializeNode(nextNode);
            dom.replaceChild(nextImage, image);
            image = nextImage;
          }
          const nextShowsMarkdown = nextDecorations.some(
            (item) => item.spec.imageMarkdown,
          );
          if (
            !currentNode.eq(nextNode) ||
            showsMarkdown !== nextShowsMarkdown
          ) {
            currentNode = nextNode;
            showsMarkdown = nextShowsMarkdown;
            render();
          }
          return true;
        },
      };
    };
  },

  addProseMirrorPlugins() {
    let isBlurred = false;
    let isSelecting = false;
    let dragImage: Element | null = null;
    const selectionAtImage = (view: EditorView, anchor: ResolvedPos) => {
      if (!dragImage || !view.dom.contains(dragImage)) return null;
      const from = view.posAtDOM(dragImage, 0);
      const node = view.state.doc.nodeAt(from);
      if (node?.type.name !== "image") return null;
      const to = from + node.nodeSize;
      if (anchor.pos > from && anchor.pos < to) return null;
      const edge = Selection.findFrom(
        view.state.doc.resolve(anchor.pos <= from ? to : from),
        anchor.pos <= from ? 1 : -1,
        true,
      );
      return edge ? new TextSelection(anchor, edge.$head) : null;
    };
    return [
      new Plugin({
        props: {
          createSelectionBetween(view, anchor) {
            return selectionAtImage(view, anchor);
          },
          handleDOMEvents: {
            mousedown(_view, event) {
              isSelecting = event.button === 0;
              dragImage = null;
              return false;
            },
            mousemove(view, event) {
              dragImage = null;
              if (!isSelecting || event.buttons !== 1) return false;
              if (!(view.state.selection instanceof TextSelection))
                return false;
              if (event.target instanceof Element)
                dragImage = event.target.closest(".selectable-image");
              const selection = selectionAtImage(
                view,
                view.state.selection.$anchor,
              );
              if (!selection) return false;
              if (!selection.eq(view.state.selection))
                view.dispatch(view.state.tr.setSelection(selection));
              event.preventDefault();
              return true;
            },
            mouseup() {
              isSelecting = false;
              dragImage = null;
              return false;
            },
            mouseleave() {
              dragImage = null;
              return false;
            },
            blur(view) {
              isSelecting = false;
              dragImage = null;
              isBlurred = true;
              const transaction = view.state.tr.setMeta(
                "imageSelectionFocus",
                false,
              );
              if (!view.state.selection.empty) {
                const cursor =
                  Selection.findFrom(view.state.selection.$head, -1, true) ||
                  Selection.atStart(view.state.doc);
                transaction.setSelection(cursor);
              }
              const nativeSelection = view.dom.ownerDocument.getSelection();
              if (
                nativeSelection?.anchorNode &&
                nativeSelection.focusNode &&
                view.dom.contains(nativeSelection.anchorNode) &&
                view.dom.contains(nativeSelection.focusNode)
              )
                nativeSelection.removeAllRanges();
              view.dispatch(transaction);
              return false;
            },
            focus(view) {
              isBlurred = false;
              view.dispatch(view.state.tr.setMeta("imageSelectionFocus", true));
              return false;
            },
          },
          decorations(state) {
            const { selection } = state;
            if (
              isBlurred ||
              selection.empty ||
              !(selection instanceof TextSelection)
            )
              return DecorationSet.empty;
            const decorations: Decoration[] = [];
            state.doc.nodesBetween(
              selection.from,
              selection.to,
              (node, pos) => {
                if (node.type.name === "image") {
                  decorations.push(
                    Decoration.node(
                      pos,
                      pos + node.nodeSize,
                      {},
                      { imageMarkdown: true },
                    ),
                  );
                }
              },
            );
            return DecorationSet.create(state.doc, decorations);
          },
        },
      }),
    ];
  },
});
