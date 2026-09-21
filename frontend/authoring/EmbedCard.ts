import { Node } from "@tiptap/core";
import type { DOMOutputSpec } from "@tiptap/pm/model";

type EmbedMetadata = {
  title: string;
  description: string | null;
  imageUrl: string | null;
  siteName: string;
  canonicalUrl: string;
};

function httpUrl(value: unknown): string | null {
  if (typeof value !== "string") return null;
  try {
    const url = new URL(value);
    return /^https?:$/.test(url.protocol) && !url.username && !url.password
      ? url.toString()
      : null;
  } catch {
    return null;
  }
}

function metadataFrom(
  value: unknown,
  fallbackUrl: string,
): EmbedMetadata | null {
  if (!value || typeof value !== "object") return null;
  const metadata = value as Record<string, unknown>;
  if (typeof metadata.title !== "string" || metadata.title.trim() === "")
    return null;
  const canonicalUrl = httpUrl(metadata.canonical_url) || fallbackUrl;
  return {
    title: metadata.title,
    description:
      typeof metadata.description === "string" ? metadata.description : null,
    imageUrl: httpUrl(metadata.image_url),
    siteName:
      typeof metadata.site_name === "string" && metadata.site_name.trim()
        ? metadata.site_name
        : new URL(canonicalUrl).hostname,
    canonicalUrl,
  };
}

function appendText(
  parent: HTMLElement,
  tag: "small" | "strong" | "span",
  className: string,
  text: string,
) {
  const element = document.createElement(tag);
  element.className = className;
  element.textContent = text;
  parent.append(element);
}

function renderMetadata(card: HTMLElement, metadata: EmbedMetadata) {
  card.replaceChildren();
  card.classList.remove("embed-card--loading");
  card.dataset.embedState = "ready";
  card.setAttribute("href", metadata.canonicalUrl);

  const content = document.createElement("span");
  content.className = "embed-card__content";
  appendText(content, "small", "embed-card__site", metadata.siteName);
  appendText(content, "strong", "embed-card__title", metadata.title);
  if (metadata.description)
    appendText(
      content,
      "span",
      "embed-card__description",
      metadata.description,
    );
  appendText(content, "span", "embed-card__url", metadata.canonicalUrl);
  card.append(content);

  if (metadata.imageUrl) {
    const image = document.createElement("img");
    image.src = metadata.imageUrl;
    image.alt = "";
    image.setAttribute("loading", "lazy");
    image.setAttribute("decoding", "async");
    image.addEventListener(
      "error",
      () => {
        image.remove();
        card.dataset.embedImage = "failed";
      },
      { once: true },
    );
    card.append(image);
  }
}

export async function hydrateEmbedCard(
  card: HTMLElement,
  fetcher: typeof fetch = fetch,
  signal?: AbortSignal,
): Promise<void> {
  const url = httpUrl(card.dataset.embedUrl);
  if (!url) {
    card.dataset.embedState = "failed";
    return;
  }
  card.dataset.embedState = "loading";
  try {
    const response = await fetcher(
      `/api/embed?${new URLSearchParams({ url })}`,
      signal ? { signal } : undefined,
    );
    if (!response.ok) throw new Error("Embed unavailable");
    const metadata = metadataFrom(await response.json(), url);
    if (!metadata) throw new Error("Invalid embed metadata");
    if (signal?.aborted) return;
    renderMetadata(card, metadata);
  } catch {
    if (!signal?.aborted) {
      card.dataset.embedState = "failed";
      card.classList.remove("embed-card--loading");
    }
  }
}

export function parseEmbedTag(source: string) {
  const match = /^\[embed:(https?:\/\/[^\s\]]+)\](?:\n|$)/.exec(source);
  if (!match || !httpUrl(match[1])) return null;
  return { raw: match[0], url: match[1] };
}

export function embedUrls(markdown: string): string[] {
  const urls = new Set<string>();
  for (const line of markdown.split("\n")) {
    const parsed = parseEmbedTag(line);
    if (parsed?.raw === line) urls.add(parsed.url);
  }
  return Array.from(urls);
}

export async function prefetchEmbedMetadata(
  markdown: string,
  fetcher: typeof fetch = fetch,
): Promise<void> {
  await Promise.allSettled(
    embedUrls(markdown).map((url) =>
      fetcher(`/api/embed?${new URLSearchParams({ url })}`),
    ),
  );
}

function placeholder(url: string): DOMOutputSpec {
  return [
    "a",
    {
      class: "embed-card embed-card--loading",
      "data-embed-url": url,
      href: url,
      target: "_blank",
      rel: "noopener noreferrer",
    },
    ["span", { class: "embed-card__url" }, url],
  ];
}

export const EmbedCard = Node.create({
  name: "embedCard",
  group: "block",
  atom: true,
  selectable: true,

  addAttributes() {
    return { url: { default: "" } };
  },

  parseHTML() {
    return [
      {
        tag: "a[data-embed-url]",
        getAttrs: (element) => ({
          url: (element as HTMLElement).dataset.embedUrl || "",
        }),
      },
    ];
  },

  renderHTML({ node }) {
    return placeholder(node.attrs.url as string);
  },

  addNodeView() {
    return ({ node }) => {
      const url = node.attrs.url as string;
      const dom = document.createElement("a");
      dom.className = "embed-card embed-card--loading";
      dom.dataset.embedUrl = url;
      dom.href = url;
      dom.target = "_blank";
      dom.rel = "noopener noreferrer";
      appendText(dom, "span", "embed-card__url", url);
      const controller = new AbortController();
      void hydrateEmbedCard(dom, fetch, controller.signal);
      return {
        dom,
        ignoreMutation: () => true,
        destroy: () => controller.abort(),
      };
    };
  },

  markdownTokenizer: {
    name: "embedCard",
    level: "block",
    start: "[embed:",
    tokenize(source) {
      const parsed = parseEmbedTag(source);
      if (parsed) return { type: "embedCard", ...parsed };
    },
  },
  parseMarkdown: (token, helpers) =>
    helpers.createNode("embedCard", { url: token.url }),
  renderMarkdown: (node) => `[embed:${node.attrs?.url || ""}]`,
});
