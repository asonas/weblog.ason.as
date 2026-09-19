import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import { acceptCheckpointChunk, type CheckpointChunk } from "./draftCheckpoint";

function chunks(data: Uint8Array): CheckpointChunk[] {
  const digest = createHash("sha256").update(data).digest("hex");
  return [data.slice(0, 3), data.slice(3)].map((part, position) => ({
    through: 4,
    digest,
    chunks: 2,
    position,
    data: Buffer.from(part).toString("base64"),
  }));
}

test("assembles and verifies a complete ordered checkpoint", async () => {
  const data = Uint8Array.from([0, 1, 2, 3, 4, 255]);
  const parts = chunks(data);
  const first = await acceptCheckpointChunk(undefined, parts[0], 1, 5);
  assert.equal(first.binary, undefined);
  const complete = await acceptCheckpointChunk(first.download, parts[1], 1, 5);
  assert.deepEqual(complete.binary, data);
});

test("rejects reordered, inconsistent, malformed, and corrupt checkpoint chunks", async () => {
  const parts = chunks(Uint8Array.from([0, 1, 2, 3, 4, 5]));
  await assert.rejects(() => acceptCheckpointChunk(undefined, parts[1], 1, 5));
  const first = await acceptCheckpointChunk(undefined, parts[0], 1, 5);
  await assert.rejects(() =>
    acceptCheckpointChunk(first.download, { ...parts[1], through: 5 }, 1, 5),
  );
  await assert.rejects(() =>
    acceptCheckpointChunk(undefined, { ...parts[0], data: "not base64" }, 1, 5),
  );
  await assert.rejects(() =>
    acceptCheckpointChunk(first.download, { ...parts[1], data: "Bg==" }, 1, 5),
  );
});
