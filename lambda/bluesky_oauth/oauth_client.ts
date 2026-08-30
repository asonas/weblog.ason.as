import { JoseKey } from "@atproto/jwk-jose";
import {
  NodeOAuthClient,
  type NodeSavedSessionStore,
} from "@atproto/oauth-client-node";

import type { EncryptedJson } from "./crypto.js";
import type { OAuthRepository } from "./repository.js";
import {
  createRequestLock,
  createSessionStore,
  createStateStore,
} from "./stores.js";

export type BlueskyOAuthConfig = {
  clientId: string;
  redirectUri: string;
  privateJwk: Record<string, unknown>;
};

export async function createOAuthClient(
  config: BlueskyOAuthConfig,
  repository: OAuthRepository,
  codec: EncryptedJson,
  sessionStore: NodeSavedSessionStore = createSessionStore(repository, codec),
): Promise<NodeOAuthClient> {
  const key = await JoseKey.fromJWK(config.privateJwk);
  return new NodeOAuthClient({
    clientMetadata: {
      client_id: config.clientId,
      client_name: "weblog.ason.as Inbox",
      client_uri: "https://weblog.ason.as",
      redirect_uris: [config.redirectUri],
      grant_types: ["authorization_code", "refresh_token"],
      scope: "atproto",
      response_types: ["code"],
      application_type: "web",
      token_endpoint_auth_method: "private_key_jwt",
      token_endpoint_auth_signing_alg: "ES256",
      dpop_bound_access_tokens: true,
      jwks_uri: "https://weblog.ason.as/oauth/bluesky/jwks.json",
    },
    keyset: [key],
    stateStore: createStateStore(repository, codec),
    sessionStore,
    requestLock: createRequestLock(repository),
    responseMode: "query",
  });
}
