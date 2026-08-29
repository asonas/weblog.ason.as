import { DsqlSigner } from "@aws-sdk/dsql-signer";
import { Client, type QueryResultRow } from "pg";

import type { OAuthConnectionStatus, OAuthRepository } from "./repository.js";

type Queryable = {
  query<T extends QueryResultRow = QueryResultRow>(text: string, values?: unknown[]): Promise<{ rows: T[]; rowCount: number | null }>;
};

export class DsqlOAuthRepository implements OAuthRepository {
  constructor(private readonly connect: () => Promise<Queryable>) {}

  static forEnvironment(hostname: string, region?: string): DsqlOAuthRepository {
    return new DsqlOAuthRepository(async () => {
      const signer = new DsqlSigner({ hostname, region });
      const client = new Client({
        host: hostname,
        port: 5432,
        database: "postgres",
        user: "weblog_authoring",
        password: await signer.getDbConnectAuthToken(),
        ssl: { rejectUnauthorized: true },
      });
      await client.connect();
      return client;
    });
  }

  async saveState(key: string, value: string, expiresAt: Date): Promise<void> {
    await this.run(async (db) => {
      await db.query(
        `INSERT INTO weblog_authoring.bluesky_oauth_states (state, encrypted_value, expires_at, created_at)
         VALUES ($1, $2, $3, NOW())
         ON CONFLICT (state) DO UPDATE SET encrypted_value = EXCLUDED.encrypted_value, expires_at = EXCLUDED.expires_at`,
        [key, value, expiresAt],
      );
    });
  }

  async consumeState(key: string): Promise<string | undefined> {
    return this.run(async (db) => {
      const result = await db.query<{ encrypted_value: string }>(
        `DELETE FROM weblog_authoring.bluesky_oauth_states
         WHERE state = $1 AND expires_at > NOW()
         RETURNING encrypted_value`,
        [key],
      );
      return result.rows[0]?.encrypted_value;
    });
  }

  async saveSession(did: string, value: string, status: OAuthConnectionStatus = "connected"): Promise<void> {
    await this.run(async (db) => {
      await db.query(
        `INSERT INTO weblog_authoring.bluesky_oauth_sessions
           (did, encrypted_value, status, created_at, updated_at)
         VALUES ($1, $2, $3, NOW(), NOW())
         ON CONFLICT (did) DO UPDATE SET encrypted_value = EXCLUDED.encrypted_value,
           status = EXCLUDED.status, updated_at = NOW()`,
        [did, value, status],
      );
    });
  }

  async getSession(did: string): Promise<{ value: string; status: OAuthConnectionStatus } | undefined> {
    return this.run(async (db) => {
      const result = await db.query<{ encrypted_value: string; status: OAuthConnectionStatus }>(
        `SELECT encrypted_value, status FROM weblog_authoring.bluesky_oauth_sessions WHERE did = $1`,
        [did],
      );
      const row = result.rows[0];
      return row ? { value: row.encrypted_value, status: row.status } : undefined;
    });
  }

  async deleteSession(did: string): Promise<void> {
    await this.run(async (db) => {
      await db.query(`DELETE FROM weblog_authoring.bluesky_oauth_sessions WHERE did = $1`, [did]);
    });
  }

  async markReauthorizationRequired(did: string): Promise<void> {
    await this.run(async (db) => {
      await db.query(
        `UPDATE weblog_authoring.bluesky_oauth_sessions
         SET status = 'reauthorization_required', updated_at = NOW() WHERE did = $1`,
        [did],
      );
    });
  }

  async withLock<T>(key: string, callback: () => Promise<T>): Promise<T> {
    const acquired = await this.run(async (db) => {
      await db.query(`DELETE FROM weblog_authoring.bluesky_oauth_locks WHERE expires_at <= NOW()`);
      const result = await db.query(
        `INSERT INTO weblog_authoring.bluesky_oauth_locks (lock_key, expires_at)
         VALUES ($1, NOW() + INTERVAL '45 seconds') ON CONFLICT (lock_key) DO NOTHING RETURNING lock_key`,
        [key],
      );
      return result.rowCount === 1;
    });
    if (!acquired) throw new Error("OAuth session is busy");
    try {
      return await callback();
    } finally {
      await this.run(async (db) => {
        await db.query(`DELETE FROM weblog_authoring.bluesky_oauth_locks WHERE lock_key = $1`, [key]);
      });
    }
  }

  private async run<T>(callback: (db: Queryable) => Promise<T>): Promise<T> {
    const db = await this.connect();
    try {
      return await callback(db);
    } finally {
      if (db instanceof Client) await db.end();
    }
  }
}
