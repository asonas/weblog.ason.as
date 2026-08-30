export type OAuthConnectionStatus = "connected" | "reauthorization_required";

export interface OAuthRepository {
  saveState(key: string, value: string, expiresAt: Date): Promise<void>;
  consumeState(key: string): Promise<string | undefined>;
  saveSession(
    did: string,
    value: string,
    status?: OAuthConnectionStatus,
  ): Promise<void>;
  getSession(
    did: string,
  ): Promise<{ value: string; status: OAuthConnectionStatus } | undefined>;
  deleteSession(did: string): Promise<void>;
  markReauthorizationRequired(did: string): Promise<void>;
  withLock<T>(key: string, callback: () => Promise<T>): Promise<T>;
}

export class MemoryOAuthRepository implements OAuthRepository {
  private readonly states = new Map<
    string,
    { value: string; expiresAt: Date }
  >();
  private readonly sessions = new Map<
    string,
    { value: string; status: OAuthConnectionStatus }
  >();
  private readonly locks = new Set<string>();

  async saveState(key: string, value: string, expiresAt: Date): Promise<void> {
    this.states.set(key, { value, expiresAt });
  }

  async consumeState(key: string): Promise<string | undefined> {
    const state = this.states.get(key);
    this.states.delete(key);
    return state && state.expiresAt > new Date() ? state.value : undefined;
  }

  async saveSession(
    did: string,
    value: string,
    status: OAuthConnectionStatus = "connected",
  ): Promise<void> {
    this.sessions.set(did, { value, status });
  }

  async getSession(
    did: string,
  ): Promise<{ value: string; status: OAuthConnectionStatus } | undefined> {
    return this.sessions.get(did);
  }

  async deleteSession(did: string): Promise<void> {
    this.sessions.delete(did);
  }

  async markReauthorizationRequired(did: string): Promise<void> {
    const session = this.sessions.get(did);
    if (session) session.status = "reauthorization_required";
  }

  async withLock<T>(key: string, callback: () => Promise<T>): Promise<T> {
    if (this.locks.has(key)) throw new Error("OAuth session is busy");
    this.locks.add(key);
    try {
      return await callback();
    } finally {
      this.locks.delete(key);
    }
  }
}
