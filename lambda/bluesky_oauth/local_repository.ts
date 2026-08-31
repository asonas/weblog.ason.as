import { randomBytes } from "node:crypto";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";

import type { OAuthConnectionStatus, OAuthRepository } from "./repository.js";

type LocalData = {
  states: Record<string, { value: string; expiresAt: string }>;
  sessions: Record<string, { value: string; status: OAuthConnectionStatus }>;
};

const EMPTY_DATA: LocalData = { states: {}, sessions: {} };

export class LocalOAuthRepository implements OAuthRepository {
  private readonly locks = new Set<string>();

  constructor(private readonly path: string) {}

  async saveState(key: string, value: string, expiresAt: Date): Promise<void> {
    const data = await this.read();
    data.states[key] = { value, expiresAt: expiresAt.toISOString() };
    await this.write(data);
  }

  async consumeState(key: string): Promise<string | undefined> {
    const data = await this.read();
    const state = data.states[key];
    delete data.states[key];
    await this.write(data);
    return state && new Date(state.expiresAt) > new Date()
      ? state.value
      : undefined;
  }

  async saveSession(
    did: string,
    value: string,
    status: OAuthConnectionStatus = "connected",
  ): Promise<void> {
    const data = await this.read();
    data.sessions[did] = { value, status };
    await this.write(data);
  }

  async getSession(did: string) {
    return (await this.read()).sessions[did];
  }

  async deleteSession(did: string): Promise<void> {
    const data = await this.read();
    delete data.sessions[did];
    await this.write(data);
  }

  async markReauthorizationRequired(did: string): Promise<void> {
    const data = await this.read();
    const session = data.sessions[did];
    if (session) session.status = "reauthorization_required";
    await this.write(data);
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

  private async read(): Promise<LocalData> {
    try {
      return JSON.parse(await readFile(this.path, "utf8")) as LocalData;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT")
        return structuredClone(EMPTY_DATA);
      throw error;
    }
  }

  private async write(data: LocalData): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true });
    const temporary = `${this.path}.${randomBytes(8).toString("hex")}.tmp`;
    await writeFile(temporary, JSON.stringify(data), { mode: 0o600 });
    await rename(temporary, this.path);
  }
}
