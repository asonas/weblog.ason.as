import assert from "node:assert/strict";
import test from "node:test";
import type { NodeSavedSession } from "@atproto/oauth-client-node";

import { EncryptedJson } from "./crypto.js";
import { MemoryOAuthRepository } from "./repository.js";
import { createSessionStore, createStateStore } from "./stores.js";

const codec = new EncryptedJson(Buffer.alloc(32, 5));

test("the OAuth SDK state store atomically consumes encrypted state", async () => {
  const repository = new MemoryOAuthRepository();
  const store = createStateStore(repository, codec);
  const value = { verifier: "pkce-secret" } as never;
  await store.set("oauth-state", value);

  assert.deepEqual(await store.get("oauth-state"), value);
  assert.equal(await store.get("oauth-state"), undefined);
});

test("a refreshed OAuth session replaces the encrypted token set", async () => {
  const repository = new MemoryOAuthRepository();
  const store = createSessionStore(repository, codec);
  const original = {
    tokenSet: { access_token: "old" },
  } as unknown as NodeSavedSession;
  const refreshed = {
    tokenSet: { access_token: "new", refresh_token: "single-use-new" },
  } as unknown as NodeSavedSession;

  await store.set("did:plc:allowed", original);
  const beforeSession = await repository.getSession("did:plc:allowed");
  assert.ok(beforeSession);
  await store.set("did:plc:allowed", refreshed);
  const afterSession = await repository.getSession("did:plc:allowed");
  assert.ok(afterSession);
  const before = beforeSession.value;
  const after = afterSession.value;

  assert.notEqual(after, before);
  assert.deepEqual(await store.get("did:plc:allowed"), refreshed);
  assert.doesNotMatch(after, /single-use-new/);
});

test("SDK deletion retains the session record and requires reauthorization", async () => {
  const repository = new MemoryOAuthRepository();
  const store = createSessionStore(repository, codec);
  await store.set("did:plc:allowed", {
    tokenSet: {},
  } as unknown as NodeSavedSession);

  await store.del("did:plc:allowed");

  assert.equal(
    (await repository.getSession("did:plc:allowed"))?.status,
    "reauthorization_required",
  );
  assert.equal(await store.get("did:plc:allowed"), undefined);
});
