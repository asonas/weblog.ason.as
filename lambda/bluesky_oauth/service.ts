import type { NodeOAuthClient } from "@atproto/oauth-client-node";

import type { EncryptedJson } from "./crypto.js";
import type { OAuthRepository } from "./repository.js";
import { StagedSessionStore } from "./stores.js";

type ClientFactory = (
  sessionStore?: StagedSessionStore,
) => Promise<NodeOAuthClient>;

export type BlueskyPost = {
  uri: string;
  cid: string;
  createdAt: string;
  canonicalUrl: string;
  authorDid: string;
};

export class BlueskyOAuthService {
  constructor(
    private readonly allowedDid: string,
    private readonly repository: OAuthRepository,
    private readonly codec: EncryptedJson,
    private readonly createClient: ClientFactory,
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
