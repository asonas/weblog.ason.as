import assert from "node:assert/strict";
import { test } from "node:test";
import * as Y from "yjs";
import { mergeLocalDraft } from "./draftLocalMerge";
import type { SavedDraft } from "./draftSession";

function initial(): SavedDraft {
  return {
    state: Y.encodeStateAsUpdate(new Y.Doc()),
    cursor: 0,
    pending: [],
    metadata: {
      title: "",
      page_type: "named",
      page_date: "",
      cover_mode: "auto",
      cover_image_url: null,
    },
    serverMetadata: {
      title: { value: "", revision: 0 },
      page_type: { value: "named", revision: 0 },
      page_date: { value: "", revision: 0 },
      cover_mode: { value: "auto", revision: 0 },
      cover_image_url: { value: null, revision: 0 },
    },
  };
}

test("stale tab saves retain another tab's pending work without resurrecting acknowledged updates", () => {
  const base = initial();
  base.pending = [{ id: "acknowledged", data: new Uint8Array([0, 0]) }];
  const stored = structuredClone(base);
  stored.pending = [{ id: "other-tab", data: new Uint8Array([0, 0]) }];
  const incoming = structuredClone(base);
  incoming.pending.push({ id: "this-tab", data: new Uint8Array([0, 0]) });
  const merged = mergeLocalDraft(base, incoming, stored);
  assert.deepEqual(merged.pending.map(({ id }) => id).sort(), [
    "other-tab",
    "this-tab",
  ]);
  const receipt = structuredClone(incoming);
  receipt.pending = [];
  assert.deepEqual(
    mergeLocalDraft(incoming, receipt, merged).pending.map(({ id }) => id),
    ["other-tab"],
  );
});

test("concurrent metadata values survive and resolving a known alternative retains unseen alternatives", () => {
  const base = initial();
  const stored = structuredClone(base);
  stored.metadata.title = "A";
  const incoming = structuredClone(base);
  incoming.metadata.title = "B";
  const merged = mergeLocalDraft(base, incoming, stored);
  assert.equal(merged.metadata.title, "B");
  assert.deepEqual(merged.tabConflicts?.title, ["A"]);
  const resolved = structuredClone(merged);
  resolved.tabConflicts = {};
  const third = structuredClone(merged);
  third.tabConflicts = { title: ["A", "C"] };
  assert.deepEqual(
    mergeLocalDraft(merged, resolved, third).tabConflicts?.title,
    ["C"],
  );
});

test("saving from a stale tab does not replace another tab's active flight", () => {
  const base = initial();
  const stored = structuredClone(base);
  stored.flight = {
    protocol: 1,
    generation: 1,
    update_id: "active",
    data: "AAA=",
    digest: "digest",
    body_bytes: 0,
    metadata: {},
    included: [],
  };
  const incoming = structuredClone(base);
  incoming.metadata.title = "追記";
  assert.equal(
    mergeLocalDraft(base, incoming, stored).flight?.update_id,
    "active",
  );
});
