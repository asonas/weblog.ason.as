import assert from "node:assert/strict";
import test from "node:test";
import type {
  NodeOAuthClient,
  NodeSavedSession,
} from "@atproto/oauth-client-node";

import { EncryptedJson } from "./crypto.js";
import { MemoryOAuthRepository } from "./repository.js";
import { BlueskyOAuthService } from "./service.js";

const allowedDid = "did:plc:allowed";
const codec = new EncryptedJson(Buffer.alloc(32, 9));
const savedSession = {
  tokenSet: { sub: allowedDid },
} as unknown as NodeSavedSession;

test("callback commits a staged session only for the allowed DID", async () => {
  const repository = new MemoryOAuthRepository();
  const service = new BlueskyOAuthService(
    allowedDid,
    repository,
    codec,
    async (store) =>
      fakeClient({
        callback: async () => {
          await store?.set(allowedDid, savedSession);
          return { session: { did: allowedDid } };
        },
      }),
  );

  await service.callback("state=valid&code=valid");

  assert.deepEqual(await service.status(), {
    status: "connected",
    did: allowedDid,
  });
  const session = await repository.getSession(allowedDid);
  assert.ok(session);
  assert.deepEqual(codec.decrypt(session.value), savedSession);
});

test("callback from another DID leaves the existing session unchanged", async () => {
  const repository = new MemoryOAuthRepository();
  await repository.saveSession(allowedDid, codec.encrypt(savedSession));
  const before = await repository.getSession(allowedDid);
  let revokedDid: string | undefined;
  const service = new BlueskyOAuthService(
    allowedDid,
    repository,
    codec,
    async (store) =>
      fakeClient({
        callback: async () => {
          await store?.set("did:plc:intruder", savedSession);
          return { session: { did: "did:plc:intruder" } };
        },
        revoke: async (did: string) => {
          revokedDid = did;
        },
      }),
  );

  await assert.rejects(
    service.callback("state=valid&code=valid"),
    /not allowed/,
  );
  assert.equal(revokedDid, "did:plc:intruder");
  assert.deepEqual(await repository.getSession(allowedDid), before);
});

test("revoked refresh requires reauthorization without deleting the session", async () => {
  const repository = new MemoryOAuthRepository();
  await repository.saveSession(allowedDid, codec.encrypt(savedSession));
  const revoked = new Error("Invalid refresh token");
  const service = new BlueskyOAuthService(
    allowedDid,
    repository,
    codec,
    async () =>
      fakeClient({
        restore: async () => {
          throw revoked;
        },
      }),
  );

  await service.refresh();

  assert.deepEqual(await service.status(), {
    status: "reauthorization_required",
    did: allowedDid,
  });
  assert.ok(await repository.getSession(allowedDid));
});

test("lists recent posts across repository pages", async () => {
  const repository = new MemoryOAuthRepository();
  await repository.saveSession(allowedDid, codec.encrypt(savedSession));
  const requests: Array<string> = [];
  const responses = [
    {
      records: [
        postRecord("new", "cid-new", "2026-08-30T09:00:00Z"),
        postRecord("middle", "cid-middle", "2026-08-29T09:00:00Z"),
      ],
      cursor: "next-page",
    },
    {
      records: [
        postRecord("boundary", "cid-boundary", "2026-08-23T09:00:00Z"),
        postRecord("old", "cid-old", "2026-08-22T08:59:59Z"),
      ],
    },
  ];
  const service = new BlueskyOAuthService(
    allowedDid,
    repository,
    codec,
    async () =>
      fakeClient({
        restore: async () => ({
          fetchHandler: async (pathname: string) => {
            requests.push(pathname);
            return Response.json(responses.shift());
          },
        }),
      }),
  );

  const posts = await service.listPosts(new Date("2026-08-23T09:00:00Z"));

  assert.deepEqual(posts, [
    {
      uri: `at://${allowedDid}/app.bsky.feed.post/new`,
      cid: "cid-new",
      createdAt: "2026-08-30T09:00:00Z",
      canonicalUrl: `https://bsky.app/profile/${allowedDid}/post/new`,
      authorDid: allowedDid,
    },
    {
      uri: `at://${allowedDid}/app.bsky.feed.post/middle`,
      cid: "cid-middle",
      createdAt: "2026-08-29T09:00:00Z",
      canonicalUrl: `https://bsky.app/profile/${allowedDid}/post/middle`,
      authorDid: allowedDid,
    },
    {
      uri: `at://${allowedDid}/app.bsky.feed.post/boundary`,
      cid: "cid-boundary",
      createdAt: "2026-08-23T09:00:00Z",
      canonicalUrl: `https://bsky.app/profile/${allowedDid}/post/boundary`,
      authorDid: allowedDid,
    },
  ]);
  assert.match(requests[0], /collection=app\.bsky\.feed\.post/);
  assert.doesNotMatch(requests[0], /reverse=/);
  assert.match(requests[1], /cursor=next-page/);
});

test("lists recent likes with hydrated post identities", async () => {
  const repository = new MemoryOAuthRepository();
  await repository.saveSession(allowedDid, codec.encrypt(savedSession));
  const requests: Array<string> = [];
  let appViewUrl: string | URL | Request | undefined;
  const service = new BlueskyOAuthService(
    allowedDid,
    repository,
    codec,
    async () =>
      fakeClient({
        restore: async () => ({
          fetchHandler: async (pathname: string) => {
            requests.push(pathname);
            if (pathname.includes("com.atproto.repo.listRecords")) {
              return Response.json({
                records: [
                  likeRecord(
                    "like-new",
                    "like-cid-new",
                    "2026-08-30T10:00:00Z",
                    "did:plc:author",
                    "post-new",
                    "subject-cid-new",
                  ),
                  likeRecord(
                    "like-old",
                    "like-cid-old",
                    "2026-08-22T08:59:59Z",
                    "did:plc:author",
                    "post-old",
                    "subject-cid-old",
                  ),
                ],
              });
            }
            return new Response(null, { status: 403 });
          },
        }),
      }),
    async (url) => {
      appViewUrl = url;
      return Response.json({
        posts: [
          {
            uri: "at://did:plc:author/app.bsky.feed.post/post-new",
            cid: "hydrated-cid-new",
            author: { did: "did:plc:author" },
          },
        ],
      });
    },
  );

  const likes = await service.listLikes(new Date("2026-08-23T09:00:00Z"));

  assert.deepEqual(likes, [
    {
      uri: `at://${allowedDid}/app.bsky.feed.like/like-new`,
      cid: "like-cid-new",
      createdAt: "2026-08-30T10:00:00Z",
      subjectUri: "at://did:plc:author/app.bsky.feed.post/post-new",
      subjectCid: "subject-cid-new",
      canonicalUrl: "https://bsky.app/profile/did:plc:author/post/post-new",
      authorDid: "did:plc:author",
    },
  ]);
  assert.match(requests[0], /collection=app\.bsky\.feed\.like/);
  assert.doesNotMatch(requests[0], /reverse=/);
  assert.equal(requests.length, 1);
  assert.match(
    String(appViewUrl),
    /^https:\/\/public\.api\.bsky\.app\/xrpc\/app\.bsky\.feed\.getPosts\?uris=at%3A%2F%2Fdid%3Aplc%3Aauthor%2Fapp\.bsky\.feed\.post%2Fpost-new$/,
  );
});

function postRecord(rkey: string, cid: string, createdAt: string) {
  return {
    uri: `at://${allowedDid}/app.bsky.feed.post/${rkey}`,
    cid,
    value: { createdAt },
  };
}

function likeRecord(
  rkey: string,
  cid: string,
  createdAt: string,
  authorDid: string,
  postRkey: string,
  subjectCid: string,
) {
  return {
    uri: `at://${allowedDid}/app.bsky.feed.like/${rkey}`,
    cid,
    value: {
      createdAt,
      subject: {
        uri: `at://${authorDid}/app.bsky.feed.post/${postRkey}`,
        cid: subjectCid,
      },
    },
  };
}

function fakeClient(overrides: Record<string, unknown>): NodeOAuthClient {
  return {
    authorize: async () => new URL("https://bsky.social/oauth/authorize"),
    callback: async () => {
      throw new Error("not implemented");
    },
    restore: async () => {
      throw new Error("not implemented");
    },
    revoke: async () => {},
    ...overrides,
  } as unknown as NodeOAuthClient;
}
