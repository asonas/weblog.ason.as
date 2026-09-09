import { Extension } from "@tiptap/core";
import { Plugin } from "@tiptap/pm/state";

import { markdownForSource } from "./markdown";

export const MarkdownClipboard = Extension.create({
  name: "markdownClipboard",

  addProseMirrorPlugins() {
    const editor = this.editor;
    return [
      new Plugin({
        props: {
          handleDOMEvents: {
            copy(view, event) {
              const { selection } = view.state;
              if (selection.empty || !event.clipboardData || !editor.markdown)
                return false;

              const markdown = editor.markdown.serialize({
                type: "doc",
                content: selection.content().content.toJSON(),
              });
              event.clipboardData.clearData();
              event.clipboardData.setData(
                "text/plain",
                markdownForSource(markdown),
              );
              event.preventDefault();
              return true;
            },
          },
        },
      }),
    ];
  },
});
