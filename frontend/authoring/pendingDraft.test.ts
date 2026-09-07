/// <reference types="node" />

import assert from "node:assert/strict";
import test from "node:test";

import { JSDOM } from "jsdom";

import {
  clearPendingDraftThrough,
  PENDING_DRAFT_FORMAT_VERSION,
  type PendingDraft,
  readPendingDraft,
  writePendingDraft,
} from "./pendingDraft";

function draft(editVersion = 1): PendingDraft {
  return {
    formatVersion: PENDING_DRAFT_FORMAT_VERSION,
    pageKey: "page-id",
    pageId: "page-id",
    baseUpdatedAt: "2026-09-07T12:00:00+09:00",
    editVersion,
    title: "title",
    body: "pending body",
    selection: { anchor: 4, head: 7 },
    scroll: { anchorText: "pending", ratio: 0.5 },
    createdAt: "2026-09-07T12:01:00+09:00",
    expiresAt: "2026-09-14T12:01:00+09:00",
  };
}

test("keeps a newer pending draft after an older save succeeds", () => {
  const storage = new JSDOM("", { url: "https://example.com" }).window
    .sessionStorage;
  writePendingDraft(storage, draft(2));

  clearPendingDraftThrough(storage, "page-id", 1);

  assert.equal(readPendingDraft(storage, "page-id")?.editVersion, 2);
  clearPendingDraftThrough(storage, "page-id", 2);
  assert.equal(readPendingDraft(storage, "page-id"), null);
});

test("discards expired and malformed pending drafts", () => {
  const storage = new JSDOM("", { url: "https://example.com" }).window
    .sessionStorage;
  writePendingDraft(storage, draft());
  assert.equal(
    readPendingDraft(storage, "page-id", new Date("2026-09-15T00:00:00Z")),
    null,
  );
  storage.setItem("weblog:pending-draft:page-id", "{broken");
  assert.equal(readPendingDraft(storage, "page-id"), null);
});
