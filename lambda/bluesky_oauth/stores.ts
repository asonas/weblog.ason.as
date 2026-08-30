import type {
  NodeSavedSession,
  NodeSavedSessionStore,
  NodeSavedState,
  NodeSavedStateStore,
  RuntimeLock,
} from "@atproto/oauth-client-node";

import type { EncryptedJson } from "./crypto.js";
import type { OAuthRepository } from "./repository.js";

export function createStateStore(
  repository: OAuthRepository,
  codec: EncryptedJson,
): NodeSavedStateStore {
  return {
    set: (key, value) =>
      repository.saveState(
        key,
        codec.encrypt(value),
        new Date(Date.now() + 10 * 60_000),
      ),
    async get(key) {
      const value = await repository.consumeState(key);
      return value ? codec.decrypt<NodeSavedState>(value) : undefined;
    },
    async del() {},
  };
}

export function createSessionStore(
  repository: OAuthRepository,
  codec: EncryptedJson,
): NodeSavedSessionStore {
  return {
    set: (did, value) => repository.saveSession(did, codec.encrypt(value)),
    async get(did) {
      const session = await repository.getSession(did);
      return session?.status === "connected"
        ? codec.decrypt<NodeSavedSession>(session.value)
        : undefined;
    },
    del: (did) => repository.markReauthorizationRequired(did),
  };
}

export function createRequestLock(repository: OAuthRepository): RuntimeLock {
  return (key, callback) => repository.withLock(key, async () => callback());
}

export class StagedSessionStore implements NodeSavedSessionStore {
  readonly sessions = new Map<string, NodeSavedSession>();

  async set(did: string, value: NodeSavedSession): Promise<void> {
    this.sessions.set(did, value);
  }

  async get(did: string): Promise<NodeSavedSession | undefined> {
    return this.sessions.get(did);
  }

  async del(did: string): Promise<void> {
    this.sessions.delete(did);
  }
}
