import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import test from "node:test";
import * as Y from "yjs";
import {
  DraftMaintenanceError,
  maintainDraftCheckpoints,
} from "./maintenance.js";
import type {
  DraftCheckpointJob,
  DraftCheckpointRepository,
  VerifiedCheckpoint,
} from "./repository.js";

class Repository implements DraftCheckpointRepository {
  activated: { articleId: string; checkpoint: VerifiedCheckpoint }[] = [];
  cleaned: string[] = [];

  constructor(readonly jobs: Record<string, DraftCheckpointJob>) {}

  async listArticleIds() {
    return Object.keys(this.jobs);
  }

  async loadJob(articleId: string) {
    return this.jobs[articleId];
  }

  async activate(articleId: string, checkpoint: VerifiedCheckpoint) {
    this.activated.push({ articleId, checkpoint });
    return "activated" as const;
  }

  async cleanup(articleId: string) {
    this.cleaned.push(articleId);
    return articleId === "due" ? 3 : 0;
  }
}

function update() {
  const doc = new Y.Doc({ gc: false });
  doc.getText("body").insert(0, "x");
  const data = Y.encodeStateAsUpdate(doc);
  doc.destroy();
  return { data, digest: createHash("sha256").update(data).digest("hex") };
}

function job(articleId: string, count: number): DraftCheckpointJob {
  const payload = update();
  return {
    articleId,
    protocol: 1,
    generation: 1,
    through: count,
    expectedCheckpoint: 0,
    updates: Array.from({ length: count }, (_, index) => ({
      ...payload,
      sequence: index + 1,
    })),
    decodedBytes: count * payload.data.byteLength,
  };
}

test("activates only due histories and runs cleanup for every article", async () => {
  const repository = new Repository({
    due: job("due", 1_000),
    small: job("small", 1),
  });
  const result = await maintainDraftCheckpoints(repository, new Date(0));
  assert.deepEqual(result, {
    checked: 2,
    activated: 1,
    unchanged: 0,
    stale: 0,
    cleaned: 3,
  });
  assert.equal(repository.activated[0].checkpoint.through, 1_000);
  assert.deepEqual(repository.cleaned, ["due", "small"]);
});

test("preserves failures while processing independent articles", async () => {
  const corrupt = job("corrupt", 1_000);
  corrupt.updates[0] = { ...corrupt.updates[0], digest: "0".repeat(64) };
  const repository = new Repository({ corrupt, small: job("small", 1) });
  let error: DraftMaintenanceError | undefined;
  try {
    await maintainDraftCheckpoints(repository);
  } catch (caught) {
    if (caught instanceof DraftMaintenanceError) error = caught;
    else throw caught;
  }
  assert.ok(error);
  assert.deepEqual(error.failures, [
    { articleId: "corrupt", message: "Stored payload digest mismatch" },
  ]);
  assert.deepEqual(repository.cleaned, ["small"]);
  assert.equal(error.result.checked, 2);
});
