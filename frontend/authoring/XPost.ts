import { Node } from "@tiptap/core";
import type { DOMOutputSpec } from "@tiptap/pm/model";

type XWidgets = {
  widgets: {
    createTweet: (
      id: string,
      target: HTMLElement,
      options?: Record<string, unknown>,
    ) => Promise<HTMLElement | null>;
  };
};

type XLoader = () => Promise<XWidgets>;
type XBootstrap = Partial<XWidgets> & {
  _e?: Array<(widgets: XWidgets) => void>;
  ready?: (callback: (widgets: XWidgets) => void) => void;
};

declare global {
  interface Window {
    twttr?: XBootstrap;
  }
}

const X_POST_URL =
  /^https:\/\/(?:www\.)?(?:x\.com|twitter\.com)\/([A-Za-z0-9_]+)\/status\/(\d+)\/?(?:\?[^\s#]*)?(?:#[^\s]*)?$/;

export function xPostIdentity(rawUrl: string) {
  const match = X_POST_URL.exec(rawUrl);
  return match ? { id: match[2], url: rawUrl } : null;
}

let widgetsPromise: Promise<XWidgets> | undefined;

function loadXWidgets(): Promise<XWidgets> {
  if (window.twttr?.widgets) return Promise.resolve(window.twttr as XWidgets);
  if (widgetsPromise) return widgetsPromise;
  widgetsPromise = new Promise((resolve, reject) => {
    const existing = window.twttr;
    if (!existing) {
      const callbacks: Array<(widgets: XWidgets) => void> = [];
      window.twttr = {
        _e: callbacks,
        ready: (callback) => {
          callbacks.push(callback);
        },
      };
    }
    window.twttr?.ready?.(resolve);
    const current = document.querySelector<HTMLScriptElement>(
      'script[src="https://platform.twitter.com/widgets.js"]',
    );
    const script = current || document.createElement("script");
    const failed = () => reject(new Error("X widgets unavailable"));
    script.addEventListener("error", failed, { once: true });
    if (!current) {
      script.src = "https://platform.twitter.com/widgets.js";
      script.async = true;
      script.charset = "utf-8";
      document.head.append(script);
    }
  });
  return widgetsPromise;
}

export async function hydrateXPost(
  container: HTMLElement,
  loader: XLoader = loadXWidgets,
): Promise<void> {
  const id = container.dataset.xPostId;
  if (!id || !/^\d+$/.test(id)) {
    container.dataset.embedState = "failed";
    return;
  }
  container.dataset.embedState = "loading";
  try {
    const fallback = container.querySelector("a");
    const rendered = await (await loader()).widgets.createTweet(id, container, {
      align: "center",
      dnt: true,
    });
    if (!rendered) throw new Error("X post unavailable");
    fallback?.remove();
    container.dataset.embedState = "ready";
  } catch {
    container.dataset.embedState = "failed";
  }
}

function parseXPost(source: string) {
  const match = /^(https:\/\/[^\s]+)(?:\n|$)/.exec(source);
  if (!match) return null;
  const identity = xPostIdentity(match[1]);
  return identity ? { raw: match[0], ...identity } : null;
}

function placeholder(id: string, url: string): DOMOutputSpec {
  return [
    "div",
    { class: "x-post", "data-x-post-id": id, "data-x-post-url": url },
    ["a", { href: url, target: "_blank", rel: "noopener noreferrer" }, url],
  ];
}

export const XPost = Node.create({
  name: "xPost",
  group: "block",
  atom: true,
  selectable: true,

  addAttributes() {
    return { id: { default: "" }, url: { default: "" } };
  },

  parseHTML() {
    return [
      {
        tag: "div[data-x-post-id]",
        getAttrs: (element) => ({
          id: (element as HTMLElement).dataset.xPostId || "",
          url: (element as HTMLElement).dataset.xPostUrl || "",
        }),
      },
    ];
  },

  renderHTML({ node }) {
    return placeholder(node.attrs.id as string, node.attrs.url as string);
  },

  addNodeView() {
    return ({ node }) => {
      const id = node.attrs.id as string;
      const url = node.attrs.url as string;
      const dom = document.createElement("div");
      dom.className = "x-post";
      dom.dataset.xPostId = id;
      dom.dataset.xPostUrl = url;
      const link = document.createElement("a");
      link.href = url;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = url;
      dom.append(link);
      void hydrateXPost(dom);
      return { dom, ignoreMutation: () => true };
    };
  },

  markdownTokenizer: {
    name: "xPost",
    level: "block",
    start: "https://",
    tokenize(source) {
      const parsed = parseXPost(source);
      if (parsed) return { type: "xPost", ...parsed };
    },
  },
  parseMarkdown: (token, helpers) =>
    helpers.createNode("xPost", { id: token.id, url: token.url }),
  renderMarkdown: (node) => node.attrs?.url || "",
});
