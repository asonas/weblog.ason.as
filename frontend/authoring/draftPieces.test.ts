import assert from "node:assert/strict";
import { test } from "node:test";
import * as Y from "yjs";
import {
  type DraftPieces,
  mergePieceDrafts,
  pieceMarkdown,
  receiveStructure,
} from "./draftPieces";
import { acceptMemoSave, type LocalMemo, memoNeedsSave } from "./memoStore";

function initial(): DraftPieces {
  const structure = {
    revision: 0,
    piece_ids: ["one", "two"],
    deleted_ids: [],
    tags: ["日記"],
  };
  return {
    local: structuredClone(structure),
    server: structure,
    conflicts: [],
    recovery: [],
  };
}

test("concurrent piece order and tag edits remain selectable while an acknowledged proposal clears pending structure", () => {
  const local = initial();
  local.local.piece_ids.reverse();
  const remote = { ...initial().server, revision: 1, tags: ["木曜日", "日記"] };
  const conflict = receiveStructure(local, remote);
  assert.deepEqual(conflict.local.piece_ids, ["two", "one"]);
  assert.deepEqual(conflict.conflicts[0].tags, ["木曜日", "日記"]);
  assert.equal(conflict.server.revision, 1);
  const acknowledged = receiveStructure(local, { ...local.local, revision: 1 });
  assert.equal(acknowledged.local.revision, 1);
  assert.deepEqual(acknowledged.conflicts, []);
});

test("two offline tabs preserve both structural proposals and the body of removed pieces", () => {
  const base = initial();
  const stored = initial();
  stored.local.tags = ["タグA"];
  stored.recovery = ["retired"];
  const incoming = initial();
  incoming.local.tags = ["タグB"];
  const merged = mergePieceDrafts(base, incoming, stored);
  assert.deepEqual(merged?.local.tags, ["タグB"]);
  assert.deepEqual(
    merged?.conflicts.map((item) => item.tags),
    [["タグA"]],
  );
  assert.deepEqual(merged?.recovery, ["retired"]);
  const doc = new Y.Doc();
  doc.getText("piece:one").insert(0, "本文\n\n---\n\n同じかけら");
  doc.getText("piece:two").insert(0, "二つ目");
  doc.getText("piece:retired").insert(0, "未送信の文章");
  assert.equal(
    pieceMarkdown(doc, { ...base.local, piece_ids: ["two", "one"] }),
    "二つ目\n\n---\n\n本文\n\n---\n\n同じかけら\n\n[[日記]]",
  );
  assert.equal(doc.getText("piece:retired").toString(), "未送信の文章");
});

test("a conflict-copy acknowledgement retains typing made during the request for the next save", () => {
  const memo: LocalMemo = {
    key: "local",
    id: "original",
    body: "送信中に追記",
    savedBody: "元の本文",
    revision: 2,
    updatedAt: "2026-10-01",
  };
  const saved = acceptMemoSave(
    memo,
    {
      kind: "save",
      path: "/api/inbox/memos/original",
      method: "PUT",
      payload: {
        operation_id: "stable",
        expected_revision: 2,
        body: "送信した本文",
      },
    },
    {
      id: "conflict-copy",
      revision: 1,
      state: "available",
      result: "preserved_as_new",
    },
  );
  assert.equal(saved.id, "conflict-copy");
  assert.equal(saved.body, "送信中に追記");
  assert.equal(saved.savedBody, "送信した本文");
  assert.equal(saved.revision, 1);
  assert.ok(memoNeedsSave(saved));
});
