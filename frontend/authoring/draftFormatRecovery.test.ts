import assert from "node:assert/strict";
import { test } from "node:test";
import * as Y from "yjs";
import { recoverLegacyFormat } from "./draftFormatRecovery";
import { mergeLocalDraft } from "./draftLocalMerge";
import type { SavedDraft } from "./draftSession";

test("archives legacy edits before the migration removes body and preserves piece edits", () => {
  const doc = new Y.Doc();
  doc.getText("body").insert(0, "未送信の文章\n\n---\n\n後半");
  const metadata = {
    title: "2026-09-29",
    page_type: "date",
    page_date: "2026-09-29",
    cover_mode: "auto",
    cover_image_url: null,
  };
  const saved: SavedDraft = {
    state: Y.encodeStateAsUpdate(doc),
    metadata,
    cursor: 1,
    serverMetadata: {
      title: { value: metadata.title, revision: 0 },
      page_type: { value: "date", revision: 0 },
      page_date: { value: metadata.page_date, revision: 0 },
      cover_mode: { value: "auto", revision: 0 },
      cover_image_url: { value: null, revision: 0 },
    },
    pending: [
      { id: "legacy", data: new Uint8Array([0, 0]) },
      { id: "piece", piece_id: "piece-id", data: new Uint8Array([0, 0]) },
    ],
    flight: {
      protocol: 1,
      generation: 1,
      update_id: "old",
      data: "AAA=",
      digest: "digest",
      body_bytes: 1,
      metadata: {},
      included: ["legacy"],
    },
  };
  const recovered = recoverLegacyFormat(saved);
  assert.equal(recovered.flight, undefined);
  assert.deepEqual(
    recovered.pending.map((update) => update.id),
    ["piece"],
  );
  assert.equal(recovered.legacyRecovery?.body, "未送信の文章\n\n---\n\n後半");
  doc.getText("body").delete(0, doc.getText("body").length);
  recovered.state = Y.encodeStateAsUpdate(doc);
  const merged = mergeLocalDraft(saved, recovered, saved);
  assert.equal(merged.legacyRecovery?.body, "未送信の文章\n\n---\n\n後半");
  assert.equal(merged.flight, undefined);
  assert.deepEqual(
    merged.pending.map((update) => update.id),
    ["piece"],
  );
  assert.deepEqual(recoverLegacyFormat(merged), merged);
  doc.destroy();
});
