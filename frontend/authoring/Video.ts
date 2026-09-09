import { Node } from "@tiptap/core";
import { DOMSerializer } from "@tiptap/pm/model";

const ASSET_PATH = /^\/assets\/uploads\/\d{4}\/\d{2}\/[a-f0-9-]+\.mp4$/;
export function videoAssetPath(value: unknown): string | null {
  return typeof value === "string" && ASSET_PATH.test(value) ? value : null;
}

function parseVideo(source: string) {
  const match =
    /^:::video (\S+?)(?: (\/assets\/\S+))?(?: ([1-9]\d{0,4})x([1-9]\d{0,4}))? :::(?:\n|$)/.exec(
      source,
    );
  if (
    !match ||
    !videoAssetPath(match[1]) ||
    (match[2] && !videoAssetPath(match[2]))
  )
    return null;
  return {
    raw: match[0],
    avc: match[1],
    av1: match[2] ?? null,
    width: match[3] ? Number(match[3]) : null,
    height: match[4] ? Number(match[4]) : null,
  };
}

function videoMarkdown(attrs: Record<string, unknown>) {
  return `:::video ${attrs.avc}${attrs.av1 ? ` ${attrs.av1}` : ""}${attrs.width && attrs.height ? ` ${attrs.width}x${attrs.height}` : ""} :::`;
}

export const Video = Node.create({
  name: "video",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes() {
    return {
      avc: { default: null },
      av1: { default: null },
      width: { default: null },
      height: { default: null },
    };
  },
  parseHTML() {
    return [
      {
        tag: "video[data-avc]",
        getAttrs: (element) => {
          const avc = videoAssetPath(element.getAttribute("data-avc"));
          return avc
            ? {
                avc,
                av1: videoAssetPath(element.getAttribute("data-av1")),
                width: Number(element.getAttribute("width")) || null,
                height: Number(element.getAttribute("height")) || null,
              }
            : false;
        },
      },
    ];
  },
  renderHTML({ node }) {
    const avc = videoAssetPath(node.attrs.avc);
    const av1 = videoAssetPath(node.attrs.av1);
    if (!avc) return ["p", {}, "動画のURLが不正です"];
    return [
      "video",
      {
        controls: "",
        playsinline: "",
        preload: "metadata",
        width: node.attrs.width,
        height: node.attrs.height,
        style: `aspect-ratio: ${node.attrs.width || 16} / ${node.attrs.height || 9}`,
        "data-avc": avc,
        "data-av1": av1,
      },
      ...(av1
        ? [
            [
              "source",
              {
                src: `${av1}#t=0.001`,
                type: 'video/mp4; codecs="av01.0.08M.08"',
              },
            ],
          ]
        : []),
      ["source", { src: `${avc}#t=0.001`, type: "video/mp4" }],
    ];
  },
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const dom = document.createElement("div");
      dom.className = "video-node";
      dom.contentEditable = "false";
      dom.append(DOMSerializer.fromSchema(editor.schema).serializeNode(node));
      const actions = document.createElement("div");
      actions.className = "video-node__actions";
      const fields = document.createElement("div");
      fields.className = "video-node__fields";
      fields.hidden = true;
      const label = document.createElement("label");
      label.textContent = "動画のMarkdown";
      const field = document.createElement("textarea");
      field.rows = 4;
      label.append(field);
      const error = document.createElement("p");
      error.setAttribute("role", "alert");
      fields.append(label, error);
      const button = (
        title: string,
        parent: HTMLElement,
        action: () => void,
      ) => {
        const control = document.createElement("button");
        control.type = "button";
        control.textContent = title;
        control.addEventListener("click", () => {
          if (editor.isEditable) action();
        });
        parent.append(control);
      };
      button("記法を編集", actions, () => {
        field.value = videoMarkdown(node.attrs);
        fields.hidden = false;
        field.focus();
      });
      button("本文から削除", actions, () => {
        const pos = getPos();
        if (typeof pos === "number")
          editor
            .chain()
            .focus()
            .deleteRange({ from: pos, to: pos + node.nodeSize })
            .run();
      });
      button("変更を反映", fields, () => {
        const parsed = parseVideo(field.value.trim());
        if (!parsed || parsed.raw !== field.value.trim()) {
          error.textContent =
            "動画の記法を確認してください。:::video H.264のパス AV1のパス 幅x高さ :::（AV1と幅x高さは省略可）";
          return;
        }
        const pos = getPos();
        if (typeof pos !== "number") return;
        editor.view.dispatch(
          editor.state.tr.setNodeMarkup(pos, undefined, parsed),
        );
        editor.commands.focus();
      });
      button("キャンセル", fields, () => {
        fields.hidden = true;
        error.textContent = "";
      });
      actions.append(fields);
      dom.append(actions);
      const syncEditable = () => {
        actions.hidden = !editor.isEditable;
      };
      syncEditable();
      editor.on("update", syncEditable);
      return {
        dom,
        stopEvent: (event) =>
          event.target instanceof window.Node && actions.contains(event.target),
        ignoreMutation: () => true,
        destroy: () => editor.off("update", syncEditable),
      };
    };
  },
  markdownTokenizer: {
    name: "video",
    level: "block",
    start: ":::video ",
    tokenize(source) {
      const parsed = parseVideo(source);
      if (parsed) return { type: "video", ...parsed };
    },
  },
  parseMarkdown: (token, helpers) =>
    helpers.createNode("video", {
      avc: token.avc,
      av1: token.av1,
      width: token.width,
      height: token.height,
    }),
  renderMarkdown: (node) => videoMarkdown(node.attrs ?? {}),
});
