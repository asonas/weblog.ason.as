import type { NodeOAuthClient } from "@atproto/oauth-client-node";

import type { EncryptedJson } from "./crypto.js";
import type { OAuthRepository } from "./repository.js";
import { StagedSessionStore } from "./stores.js";

type ClientFactory = (
  sessionStore?: StagedSessionStore,
) => Promise<NodeOAuthClient>;

type AppViewFetch = typeof fetch;

export type BlueskyPost = {
  uri: string;
  cid: string;
  createdAt: string;
  canonicalUrl: string;
  authorDid: string;
};

export type BlueskyLike = {
  uri: string;
  cid: string;
  createdAt: string;
  subjectUri: string;
  subjectCid: string;
  canonicalUrl: string;
  authorDid: string;
};

export class BlueskyOAuthService {
  constructor(
    private readonly allowedDid: string,
    private readonly repository: OAuthRepository,
    private readonly codec: EncryptedJson,
    private readonly createClient: ClientFactory,
    private readonly appViewFetch: AppViewFetch = fetch,
  ) {}

  async connect(): Promise<string> {
    const client = await this.createClient();
    return (
      await client.authorize(this.allowedDid, { scope: "atproto" })
    ).toString();
  }

  async callback(query: string): Promise<void> {
    const stagedStore = new StagedSessionStore();
    const client = await this.createClient(stagedStore);
    const { session } = await client.callback(new URLSearchParams(query));
    if (session.did !== this.allowedDid) {
      await client.revoke(session.did);
      throw new Error("Bluesky account is not allowed");
    }
    const staged = stagedStore.sessions.get(session.did);
    if (!staged) throw new Error("Bluesky OAuth session was not staged");
    await this.repository.saveSession(
      session.did,
      this.codec.encrypt(staged),
      "connected",
    );
  }

  async status(): Promise<{
    status: "disconnected" | "connected" | "reauthorization_required";
    did?: string;
  }> {
    const session = await this.repository.getSession(this.allowedDid);
    return session
      ? { status: session.status, did: this.allowedDid }
      : { status: "disconnected" };
  }

  async refresh(): Promise<void> {
    const existing = await this.repository.getSession(this.allowedDid);
    if (existing?.status !== "connected") return;
    try {
      const client = await this.createClient();
      await client.restore(this.allowedDid, true);
    } catch (error) {
      if (isRevokedSessionError(error)) {
        await this.repository.markReauthorizationRequired(this.allowedDid);
        return;
      }
      throw error;
    }
  }

  async listPosts(since: Date): Promise<Array<BlueskyPost>> {
    const client = await this.createClient();
    const session = await client.restore(this.allowedDid, "auto");
    const posts: Array<BlueskyPost> = [];
    let cursor: string | undefined;

    do {
      const query = new URLSearchParams({
        repo: this.allowedDid,
        collection: "app.bsky.feed.post",
        limit: "100",
      });
      if (cursor) query.set("cursor", cursor);
      const response = await session.fetchHandler(
        `/xrpc/com.atproto.repo.listRecords?${query.toString()}`,
      );
      if (!response.ok)
        throw new Error(`Bluesky listRecords returned ${response.status}`);

      const page = parseRecordPage(await response.json());
      for (const record of page.records) {
        const createdAt = new Date(record.value.createdAt);
        if (!Number.isFinite(createdAt.getTime()) || createdAt < since)
          continue;
        posts.push({
          uri: record.uri,
          cid: record.cid,
          createdAt: record.value.createdAt,
          canonicalUrl: canonicalPostUrl(record.uri, this.allowedDid),
          authorDid: this.allowedDid,
        });
      }
      if (
        page.records.some((record) => new Date(record.value.createdAt) < since)
      )
        break;
      cursor = page.cursor;
    } while (cursor);

    return posts;
  }

  async listLikes(since: Date): Promise<Array<BlueskyLike>> {
    const client = await this.createClient();
    const session = await client.restore(this.allowedDid, "auto");
    const records: Array<LikeRecord> = [];
    let cursor: string | undefined;

    do {
      const query = new URLSearchParams({
        repo: this.allowedDid,
        collection: "app.bsky.feed.like",
        limit: "100",
      });
      if (cursor) query.set("cursor", cursor);
      const response = await session.fetchHandler(
        `/xrpc/com.atproto.repo.listRecords?${query.toString()}`,
      );
      if (!response.ok)
        throw new Error(`Bluesky listRecords returned ${response.status}`);

      const page = parseLikeRecordPage(await response.json());
      records.push(
        ...page.records.filter(
          (record) => new Date(record.value.createdAt) >= since,
        ),
      );
      if (
        page.records.some((record) => new Date(record.value.createdAt) < since)
      )
        break;
      cursor = page.cursor;
    } while (cursor);

    const posts = new Map<string, HydratedPost>();
    for (let offset = 0; offset < records.length; offset += 25) {
      const query = new URLSearchParams();
      for (const record of records.slice(offset, offset + 25)) {
        query.append("uris", record.value.subject.uri);
      }
      const response = await this.appViewFetch(
        `https://public.api.bsky.app/xrpc/app.bsky.feed.getPosts?${query.toString()}`,
      );
      if (!response.ok)
        throw new Error(`Bluesky getPosts returned ${response.status}`);
      for (const post of parseHydratedPosts(await response.json())) {
        posts.set(post.uri, post);
      }
    }

    return records.flatMap((record) => {
      const post = posts.get(record.value.subject.uri);
      if (!post) return [];
      return [
        {
          uri: record.uri,
          cid: record.cid,
          createdAt: record.value.createdAt,
          subjectUri: record.value.subject.uri,
          subjectCid: record.value.subject.cid,
          canonicalUrl: canonicalPostUrl(post.uri, post.author.did),
          authorDid: post.author.did,
        },
      ];
    });
  }

  async disconnect(): Promise<void> {
    const existing = await this.repository.getSession(this.allowedDid);
    if (!existing) return;
    try {
      const client = await this.createClient();
      await client.revoke(this.allowedDid);
    } finally {
      await this.repository.deleteSession(this.allowedDid);
    }
  }
}

type RecordPage = {
  records: Array<{ uri: string; cid: string; value: { createdAt: string } }>;
  cursor?: string;
};

type LikeRecord = {
  uri: string;
  cid: string;
  value: {
    createdAt: string;
    subject: { uri: string; cid: string };
  };
};

type LikeRecordPage = { records: Array<LikeRecord>; cursor?: string };

type HydratedPost = {
  uri: string;
  cid: string;
  author: { did: string };
};

function parseRecordPage(value: unknown): RecordPage {
  if (!value || typeof value !== "object")
    throw new TypeError("Bluesky listRecords response must be an object");
  const page = value as { records?: unknown; cursor?: unknown };
  if (!Array.isArray(page.records))
    throw new TypeError("Bluesky listRecords records must be an array");
  const records = page.records.map((record) => {
    if (!record || typeof record !== "object")
      throw new TypeError("Bluesky post record must be an object");
    const candidate = record as {
      uri?: unknown;
      cid?: unknown;
      value?: unknown;
    };
    const post = candidate.value as { createdAt?: unknown } | undefined;
    if (
      typeof candidate.uri !== "string" ||
      typeof candidate.cid !== "string" ||
      !post ||
      typeof post.createdAt !== "string"
    )
      throw new TypeError("Bluesky post record is incomplete");
    return {
      uri: candidate.uri,
      cid: candidate.cid,
      value: { createdAt: post.createdAt },
    };
  });
  if (page.cursor !== undefined && typeof page.cursor !== "string")
    throw new TypeError("Bluesky listRecords cursor must be a string");
  return { records, cursor: page.cursor };
}

function parseLikeRecordPage(value: unknown): LikeRecordPage {
  if (!value || typeof value !== "object")
    throw new TypeError("Bluesky listRecords response must be an object");
  const page = value as { records?: unknown; cursor?: unknown };
  if (!Array.isArray(page.records))
    throw new TypeError("Bluesky listRecords records must be an array");
  const records = page.records.map((record) => {
    if (!record || typeof record !== "object")
      throw new TypeError("Bluesky like record must be an object");
    const candidate = record as {
      uri?: unknown;
      cid?: unknown;
      value?: unknown;
    };
    const like = candidate.value as
      | { createdAt?: unknown; subject?: unknown }
      | undefined;
    const subject = like?.subject as
      | { uri?: unknown; cid?: unknown }
      | undefined;
    if (
      typeof candidate.uri !== "string" ||
      typeof candidate.cid !== "string" ||
      typeof like?.createdAt !== "string" ||
      typeof subject?.uri !== "string" ||
      typeof subject.cid !== "string"
    )
      throw new TypeError("Bluesky like record is incomplete");
    return {
      uri: candidate.uri,
      cid: candidate.cid,
      value: {
        createdAt: like.createdAt,
        subject: { uri: subject.uri, cid: subject.cid },
      },
    };
  });
  if (page.cursor !== undefined && typeof page.cursor !== "string")
    throw new TypeError("Bluesky listRecords cursor must be a string");
  return { records, cursor: page.cursor };
}

function parseHydratedPosts(value: unknown): Array<HydratedPost> {
  if (!value || typeof value !== "object")
    throw new TypeError("Bluesky getPosts response must be an object");
  const response = value as { posts?: unknown };
  if (!Array.isArray(response.posts))
    throw new TypeError("Bluesky getPosts posts must be an array");
  return response.posts.map((post) => {
    if (!post || typeof post !== "object")
      throw new TypeError("Bluesky hydrated post must be an object");
    const candidate = post as {
      uri?: unknown;
      cid?: unknown;
      author?: unknown;
    };
    const author = candidate.author as { did?: unknown } | undefined;
    if (
      typeof candidate.uri !== "string" ||
      typeof candidate.cid !== "string" ||
      typeof author?.did !== "string"
    )
      throw new TypeError("Bluesky hydrated post is incomplete");
    return {
      uri: candidate.uri,
      cid: candidate.cid,
      author: { did: author.did },
    };
  });
}

function canonicalPostUrl(uri: string, did: string): string {
  const prefix = `at://${did}/app.bsky.feed.post/`;
  if (!uri.startsWith(prefix) || uri.length === prefix.length)
    throw new TypeError("Bluesky post URI is invalid");
  return `https://bsky.app/profile/${did}/post/${encodeURIComponent(uri.slice(prefix.length))}`;
}

function isRevokedSessionError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return (
    ["TokenRevokedError", "TokenInvalidError"].includes(error.name) ||
    /invalid_grant|revoked|invalid refresh token/i.test(error.message)
  );
}
