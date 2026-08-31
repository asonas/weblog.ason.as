import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { LocalOAuthRepository } from "./local_repository.js";

test("persists local OAuth state and sessions without plaintext tokens", async () => {
  const directory = await mkdtemp(join(tmpdir(), "weblog-oauth-"));
  const path = join(directory, "oauth.json");
  const repository = new LocalOAuthRepository(path);

  await repository.saveState(
    "state",
    "encrypted-state",
    new Date(Date.now() + 60_000),
  );
  await repository.saveSession("did:plc:me", "encrypted-session");

  const restarted = new LocalOAuthRepository(path);
  assert.equal(await restarted.consumeState("state"), "encrypted-state");
  assert.deepEqual(await restarted.getSession("did:plc:me"), {
    value: "encrypted-session",
    status: "connected",
  });
  assert.doesNotMatch(await readFile(path, "utf8"), /access-token/);
});
