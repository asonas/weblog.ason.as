import assert from "node:assert/strict";
import test from "node:test";
import { buildImagePaths, convertExport, convertLine } from "./scrapbox-to-weblog.ts";

test("converts Scrapbox internal links to weblog wiki links", () => {
  assert.equal(convertLine("本文 [日記] [複数 語]"), "本文 [[日記]] [[複数 語]]");
});

test("preserves external links, code, and already converted links", () => {
  assert.equal(
    convertLine("[https://example.com title] `[日記]` [[既存]]"),
    "[https://example.com title] `[日記]` [[既存]]",
  );
});

test("converts downloaded Gyazo images to local Markdown images", () => {
  const imagePaths = new Map([
    ["https://gyazo.com/407f28423dcc6ad4913886cabc6c7091", "/assets/asset_00306fc8470742b6.jpg"],
  ]);

  assert.equal(
    convertLine("[https://gyazo.com/407f28423dcc6ad4913886cabc6c7091]", imagePaths),
    "![](/assets/asset_00306fc8470742b6.jpg)",
  );
  assert.equal(
    convertLine("[https://gyazo.com/407f28423dcc6ad4913886cabc6c7091 caption]", imagePaths),
    "![](/assets/asset_00306fc8470742b6.jpg)",
  );
  assert.equal(
    convertLine("[https://gyazo.com/not-downloaded]", imagePaths),
    "[https://gyazo.com/not-downloaded]",
  );
});

test("builds image paths by joining the manifest and fetch report", () => {
  const paths = buildImagePaths(
    {
      assets: [
        { id: "asset_downloaded", kind: "image", url: "https://gyazo.com/downloaded" },
        { id: "asset_failed", kind: "image", url: "https://gyazo.com/failed" },
        { id: "asset_page", kind: "url", url: "https://example.com" },
      ],
    },
    {
      results: [
        { id: "asset_downloaded", local_path: "asset_downloaded.jpg", status: "downloaded" },
        { id: "asset_failed", status: "failed" },
        { id: "asset_page", local_path: "asset_page.html", status: "downloaded" },
      ],
    },
  );

  assert.deepEqual([...paths], [
    ["https://gyazo.com/downloaded", "/assets/asset_downloaded.jpg"],
  ]);
});

test("assets-only mode converts images without changing internal links", () => {
  const imagePaths = new Map([
    ["https://gyazo.com/image", "/assets/asset_image.jpg"],
  ]);

  assert.equal(
    convertLine("[日記] [https://gyazo.com/image]", imagePaths, "assets"),
    "[日記] ![](/assets/asset_image.jpg)",
  );
});

test("converts text lines in an export without changing page metadata", () => {
  const result = convertExport({
    projectName: "memo",
    pages: [{ title: "A", lines: [{ text: "[日記]", userId: "user" }] }],
  });

  assert.deepEqual(result, {
    projectName: "memo",
    pages: [{ title: "A", lines: [{ text: "[[日記]]", userId: "user" }] }],
  });
});

test("converts indented Scrapbox lines into nested Markdown lists", () => {
  const result = convertExport({
    pages: [{
      title: "ラジオとかvlog",
      lines: [
        "毎日更新",
        " 散財小説ドリキン",
        "  https://example.com",
        "  drikinさんがやっている[vlog]",
        " やんちゃクラブ",
        "  yancyaさんがやっているvlog",
        "  ",
      ],
    }],
  });

  assert.deepEqual(result.pages[0].lines, [
    "毎日更新",
    "- 散財小説ドリキン",
    "  - https://example.com",
    "  - drikinさんがやっている[[vlog]]",
    "- やんちゃクラブ",
    "  - yancyaさんがやっているvlog",
    "",
  ]);
});

test("does not turn code and table bodies into Markdown lists", () => {
  const result = convertExport({
    pages: [{
      title: "ブロック",
      lines: [
        "code:ts",
        " const x = 1",
        "table:csv",
        " a\tb",
        "  c\td",
        "通常の行",
        " 子の行",
      ],
    }],
  });

  assert.deepEqual(result.pages[0].lines, [
    "",
    "const x = 1",
    "",
    "a\tb",
    "c\td",
    "通常の行",
    "- 子の行",
  ]);
});
