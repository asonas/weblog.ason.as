import assert from "node:assert/strict";
import test from "node:test";
import { JoseKey } from "@atproto/jwk-jose";

import { EncryptedJson } from "./crypto.js";
import { createOAuthClient } from "./oauth_client.js";
import { MemoryOAuthRepository } from "./repository.js";

test("confidential client metadata exposes only the public ES256 key", async () => {
  const key = await JoseKey.generate(["ES256"], "bluesky-client-1");
  const client = await createOAuthClient(
    {
      clientId: "https://weblog.ason.as/oauth/bluesky/client-metadata.json",
      redirectUri: "https://weblog.ason.as/api/inbox/sources/bluesky/callback",
      privateJwk: key.privateJwk!,
    },
    new MemoryOAuthRepository(),
    new EncryptedJson(Buffer.alloc(32, 4)),
  );

  assert.equal(client.clientMetadata.token_endpoint_auth_method, "private_key_jwt");
  assert.equal(client.clientMetadata.token_endpoint_auth_signing_alg, "ES256");
  assert.deepEqual(client.clientMetadata.grant_types, ["authorization_code", "refresh_token"]);
  assert.equal(client.clientMetadata.scope, "atproto");
  assert.equal(client.jwks.keys.length, 1);
  assert.equal(client.jwks.keys[0]?.kid, "bluesky-client-1");
  assert.equal("d" in JSON.parse(JSON.stringify(client.jwks)).keys[0], false);
});
