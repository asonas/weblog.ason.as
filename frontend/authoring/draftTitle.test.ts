import assert from "node:assert/strict";
import test from "node:test";
import { draftMetadataForTitle, hasCustomDiaryTitle } from "./draftTitle";

test("treats a renamed diary as a named article", () => {
  assert.deepEqual(draftMetadataForTitle("テストの記事です。"), {
    title: "テストの記事です。",
    page_type: "named",
    page_date: "",
  });
  assert.equal(
    hasCustomDiaryTitle({
      title: "テストの記事です。",
      page_type: "date",
      page_date: "2026-09-22",
      cover_mode: "auto",
      cover_image_url: null,
    }),
    true,
  );
});

test("keeps an ISO date title as a diary", () => {
  assert.deepEqual(draftMetadataForTitle("2026-09-22"), {
    title: "2026-09-22",
    page_type: "date",
    page_date: "2026-09-22",
  });
});
