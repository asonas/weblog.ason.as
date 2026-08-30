import assert from "node:assert/strict";
import test from "node:test";

import { MemoryOAuthRepository } from "./repository.js";

test("pending OAuth state can only be consumed once", async () => {
  const repository = new MemoryOAuthRepository();
  await repository.saveState(
    "state-1",
    "encrypted",
    new Date(Date.now() + 60_000),
  );

  assert.equal(await repository.consumeState("state-1"), "encrypted");
  assert.equal(await repository.consumeState("state-1"), undefined);
});

test("expired OAuth state cannot be consumed", async () => {
  const repository = new MemoryOAuthRepository();
  await repository.saveState("state-1", "encrypted", new Date(Date.now() - 1));

  assert.equal(await repository.consumeState("state-1"), undefined);
});

test("a session lock excludes a concurrent refresh", async () => {
  const repository = new MemoryOAuthRepository();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  const first = repository.withLock("did:plc:allowed", async () => {
    await gate;
    return "first";
  });

  await assert.rejects(
    repository.withLock("did:plc:allowed", async () => "second"),
    /OAuth session is busy/,
  );
  release();
  assert.equal(await first, "first");
});
