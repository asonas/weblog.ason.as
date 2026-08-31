import { randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createServer, type ServerResponse } from "node:http";
import { dirname, resolve } from "node:path";

import {
  NodeOAuthClient,
  type NodeOAuthClientOptions,
} from "@atproto/oauth-client-node";

import { EncryptedJson } from "./crypto.js";
import { LocalOAuthRepository } from "./local_repository.js";
import { BlueskyOAuthService } from "./service.js";
import {
  createRequestLock,
  createSessionStore,
  createStateStore,
  type StagedSessionStore,
} from "./stores.js";

const host = "127.0.0.1";
const port = 8001;
const callbackUrl = `http://${host}:${port}/callback`;
const frontendUrl = "http://127.0.0.1:5173";
const dataDirectory = resolve("data/development");

async function main() {
  const allowedDid = await resolveHandle(
    process.env.BLUESKY_HANDLE ?? "ason.as",
  );
  const repository = new LocalOAuthRepository(
    resolve(dataDirectory, "bluesky-oauth.json"),
  );
  const codec = new EncryptedJson(
    await encryptionKey(resolve(dataDirectory, "bluesky-oauth.key")),
  );
  const clientId = `http://localhost?redirect_uri=${encodeURIComponent(callbackUrl)}&scope=atproto`;
  const clientMetadata: NodeOAuthClientOptions["clientMetadata"] = {
    client_id: clientId,
    client_name: "weblog.ason.as Inbox Development",
    client_uri: "http://localhost",
    redirect_uris: [callbackUrl],
    grant_types: ["authorization_code", "refresh_token"],
    scope: "atproto",
    response_types: ["code"],
    application_type: "native",
    token_endpoint_auth_method: "none",
    dpop_bound_access_tokens: true,
  };
  const factory = async (sessionStore?: StagedSessionStore) =>
    new NodeOAuthClient({
      clientMetadata,
      stateStore: createStateStore(repository, codec),
      sessionStore: sessionStore ?? createSessionStore(repository, codec),
      requestLock: createRequestLock(repository),
    });
  const service = new BlueskyOAuthService(
    allowedDid,
    repository,
    codec,
    factory,
  );

  createServer(async (request, response) => {
    try {
      const url = new URL(request.url ?? "/", callbackUrl);
      if (request.method === "GET" && url.pathname === "/connect") {
        response.writeHead(302, { location: await service.connect() });
        return response.end();
      }
      if (request.method === "GET" && url.pathname === "/callback") {
        await service.callback(url.searchParams.toString());
        response.writeHead(302, {
          location: `${frontendUrl}/?bluesky=connected`,
        });
        return response.end();
      }
      if (request.method === "GET" && url.pathname === "/status")
        return json(response, await service.status());
      if (request.method === "POST" && url.pathname === "/posts")
        return json(response, {
          posts: await service.listPosts(await cutoff(request)),
        });
      if (request.method === "POST" && url.pathname === "/likes")
        return json(response, {
          likes: await service.listLikes(await cutoff(request)),
        });
      response.writeHead(404).end("Not Found");
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      json(response, { error: message }, 500);
    }
  }).listen(port, host, () => {
    process.stdout.write(
      `Bluesky OAuth development server: http://${host}:${port}/connect\n`,
    );
  });
}

async function resolveHandle(handle: string): Promise<string> {
  const url = new URL(
    "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle",
  );
  url.searchParams.set("handle", handle);
  const response = await fetch(url);
  if (!response.ok)
    throw new Error(`Bluesky handle lookup returned ${response.status}`);
  const value = (await response.json()) as { did?: unknown };
  if (typeof value.did !== "string")
    throw new TypeError("Bluesky DID is missing");
  return value.did;
}

async function encryptionKey(path: string): Promise<Buffer> {
  try {
    return Buffer.from(await readFile(path, "utf8"), "base64");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    const key = randomBytes(32);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, key.toString("base64"), { flag: "wx", mode: 0o600 });
    return key;
  }
}

async function cutoff(
  request: import("node:http").IncomingMessage,
): Promise<Date> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) chunks.push(Buffer.from(chunk));
  const value = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
    since?: unknown;
  };
  const since = new Date(typeof value.since === "string" ? value.since : "");
  if (!Number.isFinite(since.getTime()))
    throw new TypeError("Bluesky cutoff is invalid");
  return since;
}

function json(response: ServerResponse, value: unknown, status = 200) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
  });
  response.end(JSON.stringify(value));
}

void main();
