import { Node } from "@tiptap/core";

const ASSET_PATH = /^\/assets\/uploads\/\d{4}\/\d{2}\/[a-f0-9-]+\.mp4$/;
export function videoAssetPath(value: unknown): string | null {
  return typeof value === "string" && ASSET_PATH.test(value) ? value : null;
}

export const Video = Node.create({
  name: "video",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes() {
    return { avc: { default: null }, av1: { default: null } };
  },
  parseHTML() {
    return [
      {
        tag: "video[data-avc]",
        getAttrs: (element) => {
          const avc = videoAssetPath(element.getAttribute("data-avc"));
          return avc
            ? { avc, av1: videoAssetPath(element.getAttribute("data-av1")) }
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
        preload: "none",
        "data-avc": avc,
        "data-av1": av1,
      },
      ...(av1
        ? [["source", { src: av1, type: 'video/mp4; codecs="av01.0.08M.08"' }]]
        : []),
      ["source", { src: avc, type: "video/mp4" }],
      ["a", { href: avc }, "動画をダウンロード"],
    ];
  },
  markdownTokenizer: {
    name: "video",
    level: "block",
    start: ":::video ",
    tokenize(source) {
      const match = /^:::video (\S+)(?: (\S+))? :::(?:\n|$)/.exec(source);
      if (
        !match ||
        !videoAssetPath(match[1]) ||
        (match[2] && !videoAssetPath(match[2]))
      )
        return;
      return {
        type: "video",
        raw: match[0],
        avc: match[1],
        av1: match[2] ?? null,
      };
    },
  },
  parseMarkdown: (token, helpers) =>
    helpers.createNode("video", { avc: token.avc, av1: token.av1 }),
  renderMarkdown: (node) =>
    `:::video ${node.attrs?.avc}${node.attrs?.av1 ? ` ${node.attrs.av1}` : ""} :::`,
});
