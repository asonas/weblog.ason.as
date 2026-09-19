import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import * as Y from "yjs";
import { reconstructDraft } from "./reconstruct.js";

function payload(data: Uint8Array) {
  return { data, digest: createHash("sha256").update(data).digest("hex") };
}

function history() {
  const doc = new Y.Doc({ gc: false });
  const updates: { sequence: number; data: Uint8Array; digest: string }[] = [];
  doc.on("update", (data: Uint8Array) =>
    updates.push({ sequence: updates.length + 1, ...payload(data) }),
  );
  return { doc, updates, body: doc.getText("body") };
}

test("checkpoint retains deletion-only updates and merges an old offline client and later suffix", () => {
  const source = history();
  source.body.insert(0, "残す消す");
  const offline = new Y.Doc();
  Y.applyUpdate(offline, source.updates[0].data);
  const offlineVector = Y.encodeStateVector(offline);
  const initial = reconstructDraft({
    protocol: 1,
    generation: 1,
    through: 1,
    updates: source.updates,
  });
  const vector = Y.encodeStateVector(source.doc);
  source.body.delete(2, 2);
  assert.deepEqual(Y.encodeStateVector(source.doc), vector);
  const checkpoint = reconstructDraft({
    protocol: 1,
    generation: 1,
    through: 2,
    checkpoint: initial,
    updates: source.updates.slice(1),
  });
  assert.equal(checkpoint.markdown, "残す");
  assert.notEqual(checkpoint.digest, initial.digest);

  offline.getText("body").insert(0, "古い端末の追記");
  const offlineUpdate = Y.encodeStateAsUpdate(offline, offlineVector);
  source.body.insert(source.body.length, "後続");
  const resumed = reconstructDraft({
    protocol: 1,
    generation: 1,
    through: 4,
    checkpoint,
    updates: [source.updates[2], { sequence: 4, ...payload(offlineUpdate) }],
  });
  assert.equal(resumed.markdown, "古い端末の追記残す後続");
  Y.applyUpdate(offline, resumed.data);
  assert.equal(offline.getText("body").toString(), resumed.markdown);
  assert.equal(resumed.bodyBytes, Buffer.byteLength(resumed.markdown));
  assert.equal(
    resumed.markdownDigest,
    createHash("sha256").update(resumed.markdown).digest("hex"),
  );
  source.doc.destroy();
  offline.destroy();
});

test("missing, corrupt and incompatible inputs never produce a checkpoint", () => {
  const source = history();
  source.body.insert(0, "A");
  source.body.insert(1, "B");
  const input = {
    protocol: 1,
    generation: 1,
    through: 2,
    updates: source.updates,
  };
  assert.throws(
    () => reconstructDraft({ ...input, updates: source.updates.slice(1) }),
    /Incomplete/,
  );
  assert.throws(
    () =>
      reconstructDraft({ ...input, updates: [...source.updates].reverse() }),
    /reordered/,
  );
  assert.throws(
    () => reconstructDraft({ ...input, protocol: 2 }),
    /Unsupported/,
  );
  assert.throws(
    () =>
      reconstructDraft({
        ...input,
        updates: source.updates.map((update) => ({ ...update, digest: "bad" })),
      }),
    /digest/,
  );
  assert.throws(() =>
    reconstructDraft({
      ...input,
      through: 1,
      updates: [{ sequence: 1, ...payload(new Uint8Array([255])) }],
    }),
  );
  assert.throws(
    () =>
      reconstructDraft({
        ...input,
        through: 1,
        updates: [{ ...source.updates[1], sequence: 1 }],
      }),
    /Unresolved/,
  );
  source.body.delete(0, 1);
  assert.throws(
    () =>
      reconstructDraft({
        ...input,
        through: 1,
        updates: [{ ...source.updates[2], sequence: 1 }],
      }),
    /Unresolved/,
  );
  assert.equal(source.body.toString(), "B");
  source.doc.destroy();
});

test("authoritative Markdown size and plain-text shape are checked without truncating input", () => {
  const source = history();
  source.body.insert(0, "あ".repeat(174_763));
  assert.throws(
    () =>
      reconstructDraft({
        protocol: 1,
        generation: 1,
        through: 1,
        updates: source.updates,
      }),
    /512 KiB/,
  );
  assert.equal(source.body.length, 174_763);
  const embed = history();
  embed.body.insertEmbed(0, { image: "unexpected" });
  assert.throws(
    () =>
      reconstructDraft({
        protocol: 1,
        generation: 1,
        through: 1,
        updates: embed.updates,
      }),
    /plain Markdown/,
  );
  source.doc.destroy();
  embed.doc.destroy();
});

test("oversized stored updates and checkpoints are rejected before decoding", () => {
  const input = { protocol: 1, generation: 1, through: 1, updates: [] };
  assert.throws(
    () =>
      reconstructDraft({
        ...input,
        updates: [
          { sequence: 1, ...payload(new Uint8Array(2 * 1024 * 1024 + 1)) },
        ],
      }),
    /bounds/,
  );
  assert.throws(
    () =>
      reconstructDraft({
        ...input,
        checkpoint: {
          through: 1,
          ...payload(new Uint8Array(16 * 1024 * 1024 + 1)),
        },
      }),
    /bounds/,
  );
});
