import assert from "node:assert/strict";
import test from "node:test";
import type { NodeOAuthClient, NodeSavedSession } from "@atproto/oauth-client-node";

import { EncryptedJson } from "./crypto.js";
import { MemoryOAuthRepository } from "./repository.js";
import { BlueskyOAuthService } from "./service.js";
import type { StagedSessionStore } from "./stores.js";

const allowedDid = "did:plc:allowed";
const codec = new EncryptedJson(Buffer.alloc(32, 9));
const savedSession = { tokenSet: { sub: allowedDid } } as unknown as NodeSavedSession;

test("callback commits a staged session only for the allowed DID", async () => {
  const repository = new MemoryOAuthRepository();
  const service = new BlueskyOAuthService(allowedDid, repository, codec, async (store) => fakeClient({
    callback: async () => {
      await store?.set(allowedDid, savedSession);
      return { session: { did: allowedDid } };
    },
  }));

  await service.callback("state=valid&code=valid");

  assert.deepEqual(await service.status(), { status: "connected", did: allowedDid });
  assert.deepEqual(codec.decrypt((await repository.getSession(allowedDid))!.value), savedSession);
});

test("callback from another DID leaves the existing session unchanged", async () => {
  const repository = new MemoryOAuthRepository();
  await repository.saveSession(allowedDid, codec.encrypt(savedSession));
  const before = await repository.getSession(allowedDid);
  let revokedDid: string | undefined;
  const service = new BlueskyOAuthService(allowedDid, repository, codec, async (store) => fakeClient({
    callback: async () => {
      await store?.set("did:plc:intruder", savedSession);
      return { session: { did: "did:plc:intruder" } };
    },
    revoke: async (did: string) => { revokedDid = did; },
  }));

  await assert.rejects(service.callback("state=valid&code=valid"), /not allowed/);
  assert.equal(revokedDid, "did:plc:intruder");
  assert.deepEqual(await repository.getSession(allowedDid), before);
});

test("revoked refresh requires reauthorization without deleting the session", async () => {
  const repository = new MemoryOAuthRepository();
  await repository.saveSession(allowedDid, codec.encrypt(savedSession));
  const revoked = new Error("Invalid refresh token");
  const service = new BlueskyOAuthService(allowedDid, repository, codec, async () => fakeClient({
    restore: async () => { throw revoked; },
  }));

  await service.refresh();

  assert.deepEqual(await service.status(), { status: "reauthorization_required", did: allowedDid });
  assert.ok(await repository.getSession(allowedDid));
});

function fakeClient(overrides: Record<string, unknown>): NodeOAuthClient {
  return {
    authorize: async () => new URL("https://bsky.social/oauth/authorize"),
    callback: async () => { throw new Error("not implemented"); },
    restore: async () => { throw new Error("not implemented"); },
    revoke: async () => {},
    ...overrides,
  } as unknown as NodeOAuthClient;
}
