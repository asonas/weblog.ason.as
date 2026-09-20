import { createHash, randomUUID } from "node:crypto";
import { DsqlSigner } from "@aws-sdk/dsql-signer";
import { Client, type QueryResultRow } from "pg";

import type { ReconstructionInput } from "./reconstruct.js";

const STORAGE_CHUNK_BYTES = 128 * 1024;
const UPDATE_LIMIT = 2 * 1024 * 1024;
const CHECKPOINT_LIMIT = 16 * 1024 * 1024;
const UPDATE_CHUNK_LIMIT = UPDATE_LIMIT / STORAGE_CHUNK_BYTES;
const CHECKPOINT_CHUNK_LIMIT = CHECKPOINT_LIMIT / STORAGE_CHUNK_BYTES;
const RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

type Queryable = {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: unknown[],
  ): Promise<{ rows: T[]; rowCount: number | null }>;
};

export type DraftCheckpointJob = ReconstructionInput & {
  articleId: string;
  expectedCheckpoint: number;
  decodedBytes: number;
};

export type VerifiedCheckpoint = {
  protocol: number;
  generation: number;
  through: number;
  data: Uint8Array;
  digest: string;
};

export type DraftCheckpointRepository = {
  listArticleIds(): Promise<string[]>;
  loadJob(articleId: string): Promise<DraftCheckpointJob>;
  activate(
    articleId: string,
    checkpoint: VerifiedCheckpoint,
    expectedCheckpoint: number,
  ): Promise<"activated" | "unchanged" | "stale">;
  cleanup(articleId: string, now: Date): Promise<number>;
};

export class DsqlDraftCheckpointRepository
  implements DraftCheckpointRepository
{
  constructor(
    private readonly connect: () => Promise<Queryable>,
    private readonly prefix = "weblog_authoring.",
  ) {}

  static forEnvironment(
    hostname: string,
    region?: string,
  ): DsqlDraftCheckpointRepository {
    return new DsqlDraftCheckpointRepository(async () => {
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

  async listArticleIds(): Promise<string[]> {
    return this.run(async (db) => {
      const result = await db.query<{ id: string }>(
        `SELECT id FROM ${this.prefix}draft_articles ORDER BY id`,
      );
      return result.rows.map((row) => row.id);
    });
  }

  async withCutoverMaintenance<T>(work: () => Promise<T>): Promise<T> {
    const token = randomUUID();
    await this.run(async (db) => {
      await db.query("BEGIN");
      try {
        const row = (
          await db.query<{ phase: string }>(
            `SELECT phase FROM ${this.prefix}draft_cutover_state WHERE id = 1`,
          )
        ).rows[0];
        if (row?.phase !== "open")
          throw new Error("Draft maintenance is paused");
        await db.query(
          `UPDATE ${this.prefix}draft_cutover_state SET phase = phase WHERE id = 1`,
        );
        await db.query(
          `INSERT INTO ${this.prefix}draft_cutover_operations (id, kind, phase, started_at) VALUES ($1, 'draft_maintenance', 'open', $2)`,
          [token, new Date().toISOString()],
        );
        await db.query("COMMIT");
      } catch (error) {
        await db.query("ROLLBACK");
        throw error;
      }
    });
    try {
      return await work();
    } finally {
      await this.run((db) =>
        db.query(
          `DELETE FROM ${this.prefix}draft_cutover_operations WHERE id = $1`,
          [token],
        ),
      );
    }
  }

  async loadJob(articleId: string): Promise<DraftCheckpointJob> {
    return this.run(async (db) => {
      const article = (
        await db.query<{ generation: number; head: number }>(
          `SELECT generation, head FROM ${this.prefix}draft_articles WHERE id = $1`,
          [articleId],
        )
      ).rows[0];
      if (!article) throw new Error("Draft not found");
      if (Number(article.generation) !== 1)
        throw new Error("Unsupported draft format");
      const pointer = (
        await db.query<{ sequence: number }>(
          `SELECT sequence FROM ${this.prefix}draft_checkpoint_heads WHERE article_id = $1`,
          [articleId],
        )
      ).rows[0];
      const expectedCheckpoint = Number(pointer?.sequence ?? 0);
      const checkpoint = expectedCheckpoint
        ? await this.readCheckpoint(db, articleId, expectedCheckpoint)
        : undefined;
      const manifests = await db.query<{
        update_id: string;
        sequence: number;
        digest: string;
        chunks: number;
      }>(
        `SELECT update_id, sequence, digest, chunks FROM ${this.prefix}draft_updates
         WHERE article_id = $1 AND sequence > $2 AND sequence <= $3 ORDER BY sequence`,
        [articleId, expectedCheckpoint, Number(article.head)],
      );
      const updates = [];
      let decodedBytes = 0;
      for (const manifest of manifests.rows) {
        const data = await this.readChunks(
          db,
          "draft_chunks",
          "update_id",
          articleId,
          manifest.update_id,
          Number(manifest.chunks),
          UPDATE_CHUNK_LIMIT,
        );
        if (sha256(data) !== manifest.digest)
          throw new Error("Stored payload digest mismatch");
        decodedBytes += data.byteLength;
        updates.push({
          sequence: Number(manifest.sequence),
          digest: manifest.digest,
          data,
        });
      }
      return {
        articleId,
        protocol: 1,
        generation: 1,
        through: Number(article.head),
        expectedCheckpoint,
        checkpoint,
        updates,
        decodedBytes,
      };
    });
  }

  async activate(
    articleId: string,
    checkpoint: VerifiedCheckpoint,
    expectedCheckpoint: number,
  ): Promise<"activated" | "unchanged" | "stale"> {
    return this.run(async (db) => {
      if (
        checkpoint.protocol !== 1 ||
        checkpoint.generation !== 1 ||
        !Number.isSafeInteger(checkpoint.through) ||
        checkpoint.through < 1 ||
        checkpoint.data.byteLength < 1 ||
        checkpoint.data.byteLength > CHECKPOINT_LIMIT ||
        sha256(checkpoint.data) !== checkpoint.digest
      )
        throw new Error("Invalid verified checkpoint");
      const activeBeforeStaging = await this.activeSequence(db, articleId);
      if (activeBeforeStaging === checkpoint.through) {
        const manifest = (
          await db.query<{ digest: string }>(
            `SELECT digest FROM ${this.prefix}draft_checkpoints WHERE article_id = $1 AND sequence = $2`,
            [articleId, activeBeforeStaging],
          )
        ).rows[0];
        if (manifest?.digest !== checkpoint.digest)
          throw new Error("Checkpoint content changed");
        return "unchanged";
      }
      if (activeBeforeStaging !== expectedCheckpoint) return "stale";
      const count = Math.ceil(checkpoint.data.byteLength / STORAGE_CHUNK_BYTES);
      for (let position = 0; position < count; position++) {
        const data = Buffer.from(
          checkpoint.data.slice(
            position * STORAGE_CHUNK_BYTES,
            (position + 1) * STORAGE_CHUNK_BYTES,
          ),
        ).toString("base64");
        const inserted = await db.query(
          `INSERT INTO ${this.prefix}draft_checkpoint_chunks (article_id, sequence, position, data)
           VALUES ($1, $2, $3, $4) ON CONFLICT (article_id, sequence, position) DO NOTHING RETURNING position`,
          [articleId, checkpoint.through, position, data],
        );
        if (inserted.rowCount === 0) {
          const stored = (
            await db.query<{ data: string }>(
              `SELECT data FROM ${this.prefix}draft_checkpoint_chunks
               WHERE article_id = $1 AND sequence = $2 AND position = $3`,
              [articleId, checkpoint.through, position],
            )
          ).rows[0];
          if (stored?.data !== data)
            throw new Error("Staged checkpoint content changed");
        }
      }
      await db.query("BEGIN");
      try {
        const active = await this.activeSequence(db, articleId);
        if (active === checkpoint.through) {
          const manifest = (
            await db.query<{ digest: string }>(
              `SELECT digest FROM ${this.prefix}draft_checkpoints WHERE article_id = $1 AND sequence = $2`,
              [articleId, active],
            )
          ).rows[0];
          if (manifest?.digest !== checkpoint.digest)
            throw new Error("Checkpoint content changed");
          await db.query("ROLLBACK");
          return "unchanged";
        }
        if (active !== expectedCheckpoint) {
          await db.query("ROLLBACK");
          return "stale";
        }
        const article = (
          await db.query<{ head: number }>(
            `SELECT head FROM ${this.prefix}draft_articles WHERE id = $1`,
            [articleId],
          )
        ).rows[0];
        if (!article || checkpoint.through > Number(article.head))
          throw new Error("Checkpoint exceeds document head");
        await db.query(
          `INSERT INTO ${this.prefix}draft_checkpoint_heads (article_id, sequence)
           VALUES ($1, 0) ON CONFLICT (article_id) DO NOTHING`,
          [articleId],
        );
        const changed = await db.query(
          `UPDATE ${this.prefix}draft_checkpoint_heads SET sequence = $1
           WHERE article_id = $2 AND sequence = $3 RETURNING sequence`,
          [checkpoint.through, articleId, expectedCheckpoint],
        );
        if (changed.rowCount !== 1) {
          await db.query("ROLLBACK");
          return "stale";
        }
        await db.query(
          `INSERT INTO ${this.prefix}draft_checkpoints
             (article_id, sequence, digest, chunks, activated_at)
           VALUES ($1, $2, $3, $4, $5)`,
          [
            articleId,
            checkpoint.through,
            checkpoint.digest,
            count,
            new Date().toISOString(),
          ],
        );
        await db.query("COMMIT");
        return "activated";
      } catch (error) {
        await db.query("ROLLBACK");
        throw error;
      }
    });
  }

  async cleanup(articleId: string, now: Date): Promise<number> {
    return this.run(async (db) => {
      let removed = await this.cleanupExpiredUploads(db, articleId, now);
      const sequence = await this.activeSequence(db, articleId);
      if (!sequence) return removed;
      const manifest = (
        await db.query<{ activated_at: string }>(
          `SELECT activated_at FROM ${this.prefix}draft_checkpoints WHERE article_id = $1 AND sequence = $2`,
          [articleId, sequence],
        )
      ).rows[0];
      if (
        !manifest ||
        new Date(manifest.activated_at).getTime() > now.getTime() - RETENTION_MS
      )
        return removed;
      const updates = await db.query<{ update_id: string }>(
        `SELECT update_id FROM ${this.prefix}draft_updates WHERE article_id = $1 AND sequence <= $2`,
        [articleId, sequence],
      );
      for (const update of updates.rows) {
        const result = await db.query(
          `DELETE FROM ${this.prefix}draft_chunks WHERE article_id = $1 AND update_id = $2 RETURNING position`,
          [articleId, update.update_id],
        );
        removed += result.rowCount ?? 0;
      }
      return removed;
    });
  }

  private async cleanupExpiredUploads(
    db: Queryable,
    articleId: string,
    now: Date,
  ): Promise<number> {
    const expired = await db.query<{ update_id: string }>(
      `SELECT upload.update_id FROM ${this.prefix}draft_uploads upload
       WHERE upload.article_id = $1 AND upload.created_at <= $2
         AND NOT EXISTS (
           SELECT 1 FROM ${this.prefix}draft_updates committed
           WHERE committed.article_id = upload.article_id AND committed.update_id = upload.update_id
         )`,
      [articleId, new Date(now.getTime() - RETENTION_MS).toISOString()],
    );
    let removed = 0;
    for (const upload of expired.rows) {
      const chunks = await db.query(
        `DELETE FROM ${this.prefix}draft_upload_chunks WHERE article_id = $1 AND update_id = $2 RETURNING position`,
        [articleId, upload.update_id],
      );
      const manifest = await db.query(
        `DELETE FROM ${this.prefix}draft_uploads WHERE article_id = $1 AND update_id = $2 RETURNING update_id`,
        [articleId, upload.update_id],
      );
      removed += (chunks.rowCount ?? 0) + (manifest.rowCount ?? 0);
    }
    return removed;
  }

  private async readCheckpoint(
    db: Queryable,
    articleId: string,
    sequence: number,
  ) {
    const manifest = (
      await db.query<{ digest: string; chunks: number }>(
        `SELECT digest, chunks FROM ${this.prefix}draft_checkpoints WHERE article_id = $1 AND sequence = $2`,
        [articleId, sequence],
      )
    ).rows[0];
    if (!manifest) throw new Error("Missing checkpoint manifest");
    const data = await this.readChunks(
      db,
      "draft_checkpoint_chunks",
      "sequence",
      articleId,
      sequence,
      Number(manifest.chunks),
      CHECKPOINT_CHUNK_LIMIT,
    );
    if (sha256(data) !== manifest.digest)
      throw new Error("Stored payload digest mismatch");
    return { through: sequence, digest: manifest.digest, data };
  }

  private async readChunks(
    db: Queryable,
    table: "draft_chunks" | "draft_checkpoint_chunks",
    key: "update_id" | "sequence",
    articleId: string,
    value: string | number,
    count: number,
    maxCount: number,
  ): Promise<Uint8Array> {
    if (!Number.isSafeInteger(count) || count < 1 || count > maxCount)
      throw new Error("Invalid stored manifest");
    const result = await db.query<{ position: number; data: string }>(
      `SELECT position, data FROM ${this.prefix}${table}
       WHERE article_id = $1 AND ${key} = $2 ORDER BY position`,
      [articleId, value],
    );
    if (
      result.rows.length !== count ||
      result.rows.some((row, position) => Number(row.position) !== position)
    )
      throw new Error("Incomplete stored payload");
    const chunks = result.rows.map((row) => {
      const decoded = Buffer.from(row.data, "base64");
      if (decoded.toString("base64") !== row.data)
        throw new Error("Invalid stored chunk encoding");
      return decoded;
    });
    const data = Buffer.concat(chunks);
    if (!data.byteLength || data.byteLength > maxCount * STORAGE_CHUNK_BYTES)
      throw new Error("Stored payload exceeds bounds");
    return data;
  }

  private async activeSequence(
    db: Queryable,
    articleId: string,
  ): Promise<number> {
    const pointer = (
      await db.query<{ sequence: number }>(
        `SELECT sequence FROM ${this.prefix}draft_checkpoint_heads WHERE article_id = $1`,
        [articleId],
      )
    ).rows[0];
    return Number(pointer?.sequence ?? 0);
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

function sha256(data: Uint8Array): string {
  return createHash("sha256").update(data).digest("hex");
}
