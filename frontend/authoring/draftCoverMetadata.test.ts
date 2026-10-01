import assert from "node:assert/strict";
import { test } from "node:test";
import { draftCoverMetadata } from "./draftCoverMetadata";
import type { DraftMetadata } from "./draftSession";

test("switching away from a specified cover clears its URL while preserving article fields", () => {
  const specified: DraftMetadata = {
    title: "2026-09-29",
    page_type: "date",
    page_date: "2026-09-29",
    cover_mode: "explicit",
    cover_image_url: "/assets/cover.webp",
  };
  assert.deepEqual(draftCoverMetadata(specified), specified);
  for (const mode of ["auto", "none"]) {
    assert.deepEqual(draftCoverMetadata({ ...specified, cover_mode: mode }), {
      ...specified,
      cover_mode: mode,
      cover_image_url: null,
    });
  }
});
