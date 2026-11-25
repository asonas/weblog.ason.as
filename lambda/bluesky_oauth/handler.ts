import type { APIGatewayProxyStructuredResultV2, Handler } from "aws-lambda";

import { loadSecret } from "./config.js";
import { EncryptedJson } from "./crypto.js";
import { DsqlOAuthRepository } from "./dsql_repository.js";
import { createOAuthClient } from "./oauth_client.js";
import { BlueskyOAuthService } from "./service.js";
import type { StagedSessionStore } from "./stores.js";

type InternalEvent = {
  action:
    | "connect"
    | "callback"
    | "status"
    | "refresh"
    | "disconnect"
    | "list_posts";
  query?: string;
  since?: string;
};
type ApiEvent = { rawPath?: string };

let runtimePromise: ReturnType<typeof createRuntime> | undefined;

function getRuntime(): ReturnType<typeof createRuntime> {
  runtimePromise ??= createRuntime().catch((error) => {
    runtimePromise = undefined;
    throw error;
  });
  return runtimePromise;
}

async function createRuntime() {
  const secretId = process.env.BLUESKY_OAUTH_SECRET_ID;
  const dsqlHost = process.env.DSQL_HOST;
  if (!secretId || !dsqlHost)
    throw new Error("Bluesky OAuth environment is incomplete");
  const secret = await loadSecret(secretId);
  const repository = DsqlOAuthRepository.forEnvironment(
    dsqlHost,
    process.env.AWS_REGION,
  );
  const codec = new EncryptedJson(
    Buffer.from(secret.session_encryption_key, "base64"),
  );
  const config = {
    clientId: "https://weblog.ason.as/oauth/bluesky/client-metadata.json",
    redirectUri: "https://weblog.ason.as/api/inbox/sources/bluesky/callback",
    privateJwk: secret.client_private_jwk,
  };
  const factory = (store?: StagedSessionStore) =>
    createOAuthClient(config, repository, codec, store);
  const client = await factory();
  return {
    client,
    service: new BlueskyOAuthService(
      secret.allowed_did,
      repository,
      codec,
      factory,
    ),
  };
}

export const handler: Handler<
  InternalEvent | ApiEvent,
  APIGatewayProxyStructuredResultV2 | object
> = async (event) => {
  const runtime = await getRuntime();
  if (!("action" in event)) {
    if (event.rawPath === "/oauth/bluesky/client-metadata.json")
      return json(runtime.client.clientMetadata);
    if (event.rawPath === "/oauth/bluesky/jwks.json")
      return json(runtime.client.jwks);
    return { statusCode: 404, body: "Not Found" };
  }

  switch (event.action) {
    case "connect":
      return { authorization_url: await runtime.service.connect() };
    case "callback":
      await runtime.service.callback(event.query ?? "");
      return { status: "connected" };
    case "status":
      return runtime.service.status();
    case "refresh":
      await runtime.service.refresh();
      return runtime.service.status();
    case "disconnect":
      await runtime.service.disconnect();
      return { status: "disconnected" };
    case "list_posts": {
      const since = new Date(event.since ?? "");
      if (!Number.isFinite(since.getTime()))
        throw new TypeError("Bluesky post cutoff is invalid");
      return { posts: await runtime.service.listPosts(since) };
    }
  }
  throw new Error("Unsupported Bluesky OAuth action");
};

function json(value: unknown): APIGatewayProxyStructuredResultV2 {
  return {
    statusCode: 200,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "public, max-age=300",
    },
    body: JSON.stringify(value),
  };
}
