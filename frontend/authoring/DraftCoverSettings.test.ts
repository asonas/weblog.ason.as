import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";

test("lists rendered body images in order, excluding code and duplicates", async () => {
  const dom = new JSDOM("<!doctype html>");
  Object.assign(globalThis, {
    document: dom.window.document,
    window: dom.window,
  });
  const { bodyCoverImages } = await import("./DraftCoverSettings");
  assert.deepEqual(
    bodyCoverImages(
      [
        "![first](/assets/first.webp)",
        "`![inline code](/assets/inline.webp)`",
        "```markdown\n![code](/assets/code.webp)\n```",
        "> ![second](/assets/second.webp)",
        "![duplicate](/assets/first.webp)",
        "![external](https://example.com/photo.webp)",
        "![reference][photo]\n\n[photo]: /assets/reference.webp",
      ].join("\n\n"),
    ),
    [
      { src: "/assets/first.webp", alt: "first" },
      { src: "/assets/second.webp", alt: "second" },
      { src: "https://example.com/photo.webp", alt: "external" },
      { src: "/assets/reference.webp", alt: "reference" },
    ],
  );
  assert.deepEqual(bodyCoverImages("画像のない本文"), []);
  dom.window.close();
});
