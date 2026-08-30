import type { NodeOAuthClient } from "@atproto/oauth-client-node";

import { EncryptedJson } from "./crypto.js";
import type { OAuthRepository } from "./repository.js";
import { StagedSessionStore } from "./stores.js";

type ClientFactory = (
  sessionStore?: StagedSessionStore,
) => Promise<NodeOAuthClient>;

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
    if (!existing || existing.status !== "connected") return;
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

function isRevokedSessionError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  return (
    ["TokenRevokedError", "TokenInvalidError"].includes(error.name) ||
    /invalid_grant|revoked|invalid refresh token/i.test(error.message)
  );
}
