/// <reference types="node" />
import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";
import { hydrateXPost, xPostIdentity } from "./XPost";

test("recognizes X and legacy Twitter post URLs", () => {
  assert.deepEqual(
    xPostIdentity("https://x.com/juneboku/status/2100598719246999748"),
    {
      id: "2100598719246999748",
      url: "https://x.com/juneboku/status/2100598719246999748",
    },
  );
  assert.equal(
    xPostIdentity("https://twitter.com/juneboku/status/2100598719246999748")
      ?.id,
    "2100598719246999748",
  );
  assert.equal(xPostIdentity("https://x.com/juneboku"), null);
  assert.equal(xPostIdentity("https://x.com.evil.example/a/status/123"), null);
});

test("hydrates an X placeholder with the official widget API", async () => {
  const dom = new JSDOM(
    '<div class="x-post" data-x-post-id="2100598719246999748" data-x-post-url="https://x.com/juneboku/status/2100598719246999748"><a href="https://x.com/juneboku/status/2100598719246999748">Xで表示</a></div>',
  );
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document,
    HTMLElement: dom.window.HTMLElement,
  });
  try {
    const container = document.querySelector<HTMLElement>(".x-post");
    assert.ok(container);
    let requestedId = "";
    await hydrateXPost(container, async () => ({
      widgets: {
        createTweet: async (id, target) => {
          requestedId = id;
          const iframe = document.createElement("iframe");
          target.append(iframe);
          return iframe;
        },
      },
    }));
    assert.equal(requestedId, "2100598719246999748");
    assert.equal(container.dataset.embedState, "ready");
    assert.ok(container.querySelector("iframe"));
    assert.equal(container.querySelector("a"), null);
  } finally {
    dom.window.close();
  }
});
