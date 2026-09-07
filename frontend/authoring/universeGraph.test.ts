import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { act, type ComponentProps, createElement } from "react";
import { createRoot } from "react-dom/client";

const dom = new JSDOM("<!doctype html><body></body>");
Object.assign(globalThis, {
  window: dom.window,
  document: dom.window.document,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
  matchMedia: () => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {},
  }),
  ResizeObserver: class {
    observe() {}
    disconnect() {}
  },
});
const { UniverseGraph } = await import("./UniverseGraph");
window.matchMedia = globalThis.matchMedia;
type GraphProps = ComponentProps<typeof UniverseGraph>;
const baseProps: GraphProps = {
  groups: [],
  pages: [],
  route: "article",
  hasMore: false,
  loading: false,
  loadMore() {},
};

async function withGraph(
  props: Partial<GraphProps>,
  check: (container: HTMLElement) => Promise<void>,
) {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () =>
      root.render(createElement(UniverseGraph, { ...baseProps, ...props })),
    );
    await check(container);
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
}

async function activate(container: HTMLElement, name: string) {
  const node = [...container.querySelectorAll<SVGElement>(".ug-node")].find(
    (node) => node.textContent === name,
  );
  assert.ok(node);
  await act(async () =>
    node.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "Enter", bubbles: true }),
    ),
  );
  return node;
}

test("represents incoming articles and preserves connection size and age opacity", async () => {
  const old = {
    id: "old",
    route: "old",
    title: "Old",
    excerpt: "",
    created_at: "2020-01-01T00:00:00Z",
  };
  const recent = {
    id: "recent",
    route: "recent",
    title: "Recent",
    excerpt: "",
    created_at: "2026-01-01T00:00:00Z",
  };
  const incoming = {
    id: "backlink",
    route: "writing",
    title: "Writing",
    excerpt: "",
    related_by: ["article"],
    image_url: "https://example.com/article-cover.png",
  };
  await withGraph(
    {
      pages: [old, recent, incoming],
      groups: [
        { kind: "wiki", name: "Sunday", pages: [old, recent] },
        { kind: "wiki", name: "Diary", pages: [old] },
      ],
    },
    async (container) => {
      assert.match(
        container
          .querySelector('[data-node-id="wiki:writing"]')
          ?.getAttribute("aria-label") || "",
        /この記事へのリンク元/,
      );
      assert.equal(container.querySelectorAll(".ug-incoming").length, 1);
      const oldDot = container.querySelector(
        '[data-node-id="wiki:old"] circle:last-of-type',
      );
      const newDot = container.querySelector(
        '[data-node-id="wiki:recent"] circle:last-of-type',
      );
      assert.equal(oldDot?.getAttribute("r"), "8.5");
      assert.equal(newDot?.getAttribute("r"), "7");
      assert.equal(oldDot?.getAttribute("fill-opacity"), "0.35");
      assert.equal(newDot?.getAttribute("fill-opacity"), "1");
      const trigger = await activate(container, "Writing");
      assert.equal(
        document.querySelector(".ug-detail img")?.getAttribute("src"),
        "https://example.com/article-cover.png",
      );
      assert.equal(
        document.querySelector(".ug-detail a")?.getAttribute("href"),
        "/writing",
      );
      await act(async () =>
        document.dispatchEvent(
          new dom.window.KeyboardEvent("keydown", {
            key: "Escape",
            bubbles: true,
          }),
        ),
      );
      assert.equal(document.querySelector(".ug-detail"), null);
      assert.equal(document.activeElement, trigger);
    },
  );
});

test("fetches OGP only on selection and keeps links usable after a failed preview", async () => {
  const originalFetch = globalThis.fetch;
  const requests: string[] = [];
  globalThis.fetch = async (input) => {
    const url = String(input);
    requests.push(url);
    if (url.includes("broken"))
      return new Response("unavailable", { status: 503 });
    return new Response(
      JSON.stringify({
        title: "OGP title",
        description: "OGP description",
        image_url: "https://example.com/image.png",
      }),
    );
  };
  try {
    await withGraph(
      {
        groups: [
          { kind: "url", name: "https://example.com/page", pages: [] },
          { kind: "url", name: "https://example.com/broken", pages: [] },
          { kind: "url", name: "javascript:alert(1)", pages: [] },
        ],
      },
      async (container) => {
        assert.equal(requests.length, 0);
        assert.equal(container.querySelectorAll(".ug-node-direct").length, 2);
        await activate(container, "example.com/page");
        assert.equal(
          document.querySelector(".ug-detail strong")?.textContent,
          "OGP title",
        );
        assert.equal(
          document.querySelector(".ug-detail img")?.getAttribute("src"),
          "https://example.com/image.png",
        );
        assert.equal(
          document.querySelectorAll(".ug-detail-header svg").length,
          2,
        );
        const image = document.querySelector(".ug-detail img");
        assert.ok(image);
        await act(async () =>
          image.dispatchEvent(new dom.window.Event("error")),
        );
        assert.equal(document.querySelector(".ug-detail header"), null);
        assert.equal(
          document.querySelector(".ug-ogp")?.getAttribute("href"),
          "https://example.com/page",
        );
        await act(async () => document.body.click());
        await activate(container, "example.com/page");
        assert.equal(requests.length, 1);
        await activate(container, "example.com/broken");
        assert.equal(document.querySelector(".ug-detail header"), null);
        assert.match(
          document.querySelector(".ug-detail")?.textContent || "",
          /取得できません/,
        );
        assert.equal(
          document.querySelector(".ug-ogp")?.getAttribute("href"),
          "https://example.com/broken",
        );
      },
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("mobile lanes expose incoming articles and linked pages without tiny tap targets", async () => {
  const matchMedia = window.matchMedia;
  window.matchMedia = () => ({ ...matchMedia(""), matches: true });
  const related = {
    id: "related",
    route: "related",
    title: "Related",
    excerpt: "",
    related_by: ["article"],
  };
  try {
    await withGraph(
      {
        pages: [related],
        groups: [
          { kind: "wiki", name: "Topic", pages: [related] },
          { kind: "wiki", name: "日曜日", pages: [] },
        ],
      },
      async (container) => {
        assert.equal(
          container.querySelector('[data-node-id="wiki:日曜日"]'),
          null,
        );
        await activate(container, "Topic");
        assert.equal(
          document.querySelector(".ug-detail-links a")?.getAttribute("href"),
          "/related",
        );
        const incoming = [
          ...container.querySelectorAll<HTMLButtonElement>(".ug-lanes button"),
        ].find((button) => button.textContent === "リンク元");
        assert.ok(incoming);
        await act(async () => incoming.click());
        assert.ok(
          container.querySelector(
            '[data-node-id="wiki:related"].ug-node-incoming',
          ),
        );
        assert.equal(document.querySelector(".ug-detail"), null);
      },
    );
  } finally {
    window.matchMedia = matchMedia;
  }
});

test("imageless details omit header actions and dismiss only outside the card", async () => {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  try {
    await act(async () =>
      root.render(
        createElement(UniverseGraph, {
          groups: [],
          pages: [],
          route: "article",
          hasMore: false,
          loading: false,
          loadMore() {},
        }),
      ),
    );
    const node = container.querySelector('[data-node-id="root"]');
    assert.ok(node);
    await act(async () =>
      node.dispatchEvent(
        new dom.window.KeyboardEvent("keydown", {
          key: "Enter",
          bubbles: true,
        }),
      ),
    );
    const card = document.querySelector(".ug-detail");
    assert.ok(card);
    assert.equal(card.querySelector("header"), null);
    await act(async () =>
      card.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })),
    );
    assert.equal(document.activeElement, card);
    assert.ok(document.querySelector(".ug-detail"));
    await act(async () => document.body.click());
    assert.equal(document.querySelector(".ug-detail"), null);
  } finally {
    await act(async () => root.unmount());
    container.remove();
  }
});

test("hit testing selects the visible node after screen scaling and does not close a newly opened card", async () => {
  const originalPoint = globalThis.DOMPoint;
  const originalMatrix = Object.getOwnPropertyDescriptor(
    dom.window.SVGElement.prototype,
    "getScreenCTM",
  );
  Object.assign(globalThis, {
    DOMPoint: class {
      constructor(
        public x: number,
        public y: number,
      ) {}
      matrixTransform(matrix: DOMMatrix) {
        return {
          x: this.x * matrix.a + matrix.e,
          y: this.y * matrix.d + matrix.f,
        };
      }
    },
  });
  Object.defineProperty(dom.window.SVGElement.prototype, "getScreenCTM", {
    configurable: true,
    value: () => ({ a: 1.5, b: 0, c: 0, d: 1.5, e: 25, f: 50 }),
  });
  const pages = Array.from({ length: 32 }, (_, index) => ({
    id: `page-${index}`,
    route: `page-${index}`,
    title: `Page ${index}`,
    excerpt: "",
  }));
  try {
    await withGraph(
      {
        pages,
        groups: [
          { kind: "wiki", name: "日曜日", pages },
          { kind: "wiki", name: "日記", pages: pages.slice(0, 4) },
          { kind: "url", name: "https://jnbk.app/days/2026-09-04", pages: [] },
        ],
      },
      async (container) => {
        const canvas = container.querySelector(".ug-canvas");
        assert.ok(canvas);
        for (const node of container.querySelectorAll<SVGElement>(".ug-node")) {
          const position = node
            .getAttribute("transform")
            ?.match(/translate\(([-\d.]+) ([-\d.]+)\)/);
          assert.ok(position);
          const point = {
            bubbles: true,
            clientX: Number(position[1]) * 1.5 + 25,
            clientY: Number(position[2]) * 1.5 + 50,
          };
          await act(async () =>
            canvas.dispatchEvent(
              new dom.window.MouseEvent("pointermove", point),
            ),
          );
          assert.equal(
            canvas.getAttribute("data-hovered-node"),
            node.dataset.nodeId,
          );
          if (node.dataset.nodeId === "wiki:日記") {
            await act(async () =>
              canvas.dispatchEvent(new dom.window.MouseEvent("click", point)),
            );
            assert.equal(
              document.querySelector(".ug-detail")?.getAttribute("aria-label"),
              "日記",
            );
            await act(async () => document.body.click());
          }
        }
      },
    );
  } finally {
    Object.assign(globalThis, { DOMPoint: originalPoint });
    if (originalMatrix)
      Object.defineProperty(
        dom.window.SVGElement.prototype,
        "getScreenCTM",
        originalMatrix,
      );
    else
      Reflect.deleteProperty(dom.window.SVGElement.prototype, "getScreenCTM");
  }
});
