import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { DsqlSigner } from "@aws-sdk/dsql-signer";
import { Client } from "pg";
import * as Y from "yjs";
import { maintainDraftCheckpoints } from "../../../lambda/draft_worker/maintenance.js";
import { DsqlDraftCheckpointRepository } from "../../../lambda/draft_worker/repository.js";

const host = process.env.DSQL_HOST;
if (!host) throw new Error("DSQL_HOST is required");
const region = process.env.AWS_REGION || "ap-northeast-1";
const schema = `draft_verify_${randomBytes(6).toString("hex")}`;
const articleId = crypto.randomUUID();

async function connect() {
  const signer = new DsqlSigner({ hostname: host, region });
  const client = new Client({
    host,
    port: 5432,
    database: "postgres",
    user: "admin",
    password: await signer.getDbConnectAdminAuthToken(),
    ssl: { rejectUnauthorized: true },
  });
  await client.connect();
  return client;
}

const setup = await connect();
try {
  await setup.query(`CREATE SCHEMA ${schema}`);
  await setup.query(
    `CREATE TABLE ${schema}.draft_articles (id TEXT PRIMARY KEY, generation INTEGER NOT NULL, head INTEGER NOT NULL, metadata TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)`,
  );
  await setup.query(
    `CREATE TABLE ${schema}.draft_updates (article_id TEXT NOT NULL, update_id TEXT NOT NULL, sequence INTEGER NOT NULL, digest TEXT NOT NULL, fingerprint TEXT NOT NULL, receipt TEXT NOT NULL, chunks INTEGER NOT NULL, PRIMARY KEY (article_id, update_id))`,
  );
  await setup.query(
    `CREATE TABLE ${schema}.draft_chunks (article_id TEXT NOT NULL, update_id TEXT NOT NULL, position INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (article_id, update_id, position))`,
  );
  await setup.query(
    `CREATE TABLE ${schema}.draft_uploads (article_id TEXT NOT NULL, update_id TEXT NOT NULL, digest TEXT NOT NULL, fingerprint TEXT NOT NULL, body_bytes INTEGER NOT NULL, metadata TEXT NOT NULL, chunks INTEGER NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (article_id, update_id))`,
  );
  await setup.query(
    `CREATE TABLE ${schema}.draft_upload_chunks (article_id TEXT NOT NULL, update_id TEXT NOT NULL, position INTEGER NOT NULL, digest TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY (article_id, update_id, position))`,
  );
  await setup.query(
    `CREATE TABLE ${schema}.draft_checkpoint_heads (article_id TEXT PRIMARY KEY, sequence INTEGER NOT NULL)`,
  );
  await setup.query(
    `CREATE TABLE ${schema}.draft_checkpoints (article_id TEXT NOT NULL, sequence INTEGER NOT NULL, digest TEXT NOT NULL, chunks INTEGER NOT NULL, activated_at TEXT NOT NULL, PRIMARY KEY (article_id, sequence))`,
  );
  await setup.query(
    `CREATE TABLE ${schema}.draft_checkpoint_chunks (article_id TEXT NOT NULL, sequence INTEGER NOT NULL, position INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (article_id, sequence, position))`,
  );

  const doc = new Y.Doc({ gc: false });
  const body = doc.getText("body");
  body.insert(0, "x".repeat(1_300_000));
  body.delete(0, 1_300_000);
  const update = Y.encodeStateAsUpdate(doc);
  doc.destroy();
  assert.ok(update.byteLength > 1024 * 1024);
  assert.ok(update.byteLength < 2 * 1024 * 1024);
  const digest = createHash("sha256").update(update).digest("hex");
  const chunks = Array.from(
    { length: Math.ceil(update.byteLength / (128 * 1024)) },
    (_, position) =>
      Buffer.from(
        update.slice(position * 128 * 1024, (position + 1) * 128 * 1024),
      ).toString("base64"),
  );
  const now = new Date().toISOString();
  await setup.query(
    `INSERT INTO ${schema}.draft_articles (id, generation, head, metadata, created_at, updated_at) VALUES ($1, 1, 1, '{}', $2, $2)`,
    [articleId, now],
  );
  await setup.query(
    `INSERT INTO ${schema}.draft_updates (article_id, update_id, sequence, digest, fingerprint, receipt, chunks) VALUES ($1, 'update-1', 1, $2, 'fingerprint', '{"sequence":1}', $3)`,
    [articleId, digest, chunks.length],
  );
  for (const [position, data] of chunks.entries())
    await setup.query(
      `INSERT INTO ${schema}.draft_chunks (article_id, update_id, position, data) VALUES ($1, 'update-1', $2, $3)`,
      [articleId, position, data],
    );

  const repository = new DsqlDraftCheckpointRepository(
    connect,
    `${schema}.`,
  );
  const compacted = await maintainDraftCheckpoints(repository);
  assert.equal(compacted.activated, 1);
  const pointer = await setup.query<{ sequence: number }>(
    `SELECT sequence FROM ${schema}.draft_checkpoint_heads WHERE article_id = $1`,
    [articleId],
  );
  assert.equal(Number(pointer.rows[0].sequence), 1);
  await setup.query(
    `UPDATE ${schema}.draft_checkpoints SET activated_at = $1 WHERE article_id = $2 AND sequence = 1`,
    [new Date(Date.now() - 8 * 24 * 60 * 60 * 1000).toISOString(), articleId],
  );
  const expiredAt = new Date(
    Date.now() - 8 * 24 * 60 * 60 * 1000,
  ).toISOString();
  await setup.query(
    `INSERT INTO ${schema}.draft_uploads (article_id, update_id, digest, fingerprint, body_bytes, metadata, chunks, created_at) VALUES ($1, 'abandoned', $2, 'fingerprint', 0, '{}', 1, $3)`,
    [articleId, createHash("sha256").update("partial").digest("hex"), expiredAt],
  );
  await setup.query(
    `INSERT INTO ${schema}.draft_upload_chunks (article_id, update_id, position, digest, data) VALUES ($1, 'abandoned', 0, $2, $3)`,
    [
      articleId,
      createHash("sha256").update("partial").digest("hex"),
      Buffer.from("partial").toString("base64"),
    ],
  );
  const cleaned = await maintainDraftCheckpoints(repository);
  assert.equal(cleaned.cleaned, chunks.length + 2);
  const remaining = await setup.query<{ count: string }>(
    `SELECT count(*) FROM ${schema}.draft_chunks WHERE article_id = $1`,
    [articleId],
  );
  const receipts = await setup.query<{ count: string }>(
    `SELECT count(*) FROM ${schema}.draft_updates WHERE article_id = $1`,
    [articleId],
  );
  assert.equal(Number(remaining.rows[0].count), 0);
  assert.equal(Number(receipts.rows[0].count), 1);
  const uploads = await setup.query<{ count: string }>(
    `SELECT count(*) FROM ${schema}.draft_uploads WHERE article_id = $1`,
    [articleId],
  );
  assert.equal(Number(uploads.rows[0].count), 0);
  console.log(
    JSON.stringify({ schema, updateBytes: update.byteLength, chunks: chunks.length }),
  );
} finally {
  await setup.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
  await setup.end();
}
