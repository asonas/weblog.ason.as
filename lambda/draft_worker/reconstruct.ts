import { createHash } from "node:crypto";
import * as Y from "yjs";

const BODY_LIMIT = 512 * 1024;
const UPDATE_LIMIT = 2 * 1024 * 1024;
const CHECKPOINT_LIMIT = 16 * 1024 * 1024;

type Payload = { data: Uint8Array; digest: string };
export type PieceStructure = {
  revision: number;
  piece_ids: string[];
  deleted_ids: string[];
  tags: string[];
};

export function parsePieceStructure(value: unknown): PieceStructure {
  if (
    !value ||
    typeof value !== "object" ||
    !("revision" in value) ||
    typeof value.revision !== "number" ||
    !Number.isSafeInteger(value.revision) ||
    value.revision < 0 ||
    !("piece_ids" in value) ||
    !Array.isArray(value.piece_ids) ||
    !value.piece_ids.every(
      (id: unknown) =>
        typeof id === "string" &&
        /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
          id,
        ),
    ) ||
    !("deleted_ids" in value) ||
    !Array.isArray(value.deleted_ids) ||
    !value.deleted_ids.every((id: unknown) => typeof id === "string") ||
    !("tags" in value) ||
    !Array.isArray(value.tags) ||
    !value.tags.every(
      (tag: unknown) =>
        typeof tag === "string" && !!tag.trim() && !/[[\]\r\n]/.test(tag),
    )
  )
    throw new Error("Invalid piece structure");
  const deletedIds = value.deleted_ids;
  if (
    new Set(value.piece_ids).size !== value.piece_ids.length ||
    value.piece_ids.some((id: string) => deletedIds.includes(id))
  )
    throw new Error("Invalid piece membership");
  return {
    revision: value.revision,
    piece_ids: value.piece_ids,
    deleted_ids: value.deleted_ids,
    tags: value.tags,
  };
}

export type ReconstructionInput = {
  format?: "legacy" | "pieces";
  structure?: PieceStructure;
  protocol: number;
  generation: number;
  through: number;
  checkpoint?: Payload & { through: number };
  updates: (Payload & { sequence: number })[];
};

function sha256(data: Uint8Array | string): string {
  return createHash("sha256").update(data).digest("hex");
}

export function seedPiece(pieceId: unknown, body: unknown) {
  if (
    typeof pieceId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
      pieceId,
    ) ||
    typeof body !== "string" ||
    Buffer.byteLength(body) > BODY_LIMIT
  )
    throw new Error("Invalid initial piece");
  const doc = new Y.Doc({ gc: false });
  try {
    doc.getText(`piece:${pieceId}`).insert(0, body);
    const data = Y.encodeStateAsUpdate(doc);
    return {
      piece_id: pieceId,
      data: Buffer.from(data).toString("base64"),
      digest: sha256(data),
      body_digest: sha256(body),
      body_bytes: Buffer.byteLength(body),
    };
  } finally {
    doc.destroy();
  }
}

function verifyPayload(payload: Payload, limit: number) {
  if (!payload.data.byteLength || payload.data.byteLength > limit)
    throw new Error("Stored payload exceeds bounds");
  if (sha256(payload.data) !== payload.digest)
    throw new Error("Stored payload digest mismatch");
}

function requireComplete(doc: Y.Doc) {
  // Yjs 13.6.32 retains unresolved structures and deletions without throwing.
  if (doc.store.pendingStructs || doc.store.pendingDs)
    throw new Error("Unresolved Yjs dependencies");
}

function verifyCoverage(inputs: Payload[], checkpoint: Uint8Array) {
  const vector = Y.decodeStateVector(Y.encodeStateVectorFromUpdate(checkpoint));
  const deletions = Y.decodeUpdate(checkpoint).ds.clients;
  for (const input of inputs) {
    const decoded = Y.decodeUpdate(input.data);
    for (const struct of decoded.structs) {
      if ((vector.get(struct.id.client) ?? 0) < struct.id.clock + struct.length)
        throw new Error("Checkpoint omits input structures");
    }
    for (const [client, ranges] of decoded.ds.clients) {
      const covered = deletions.get(client) || [];
      for (const range of ranges) {
        if (
          !covered.some(
            (item) =>
              item.clock <= range.clock &&
              item.clock + item.len >= range.clock + range.len,
          )
        )
          throw new Error("Checkpoint omits input deletions");
      }
    }
  }
}

export function reconstructDraft(input: ReconstructionInput) {
  if (input.protocol !== 1 || input.generation !== 1)
    throw new Error("Unsupported draft format");
  const start = input.checkpoint?.through ?? 0;
  if (
    !Number.isSafeInteger(start) ||
    start < 0 ||
    !Number.isSafeInteger(input.through) ||
    input.through < start ||
    input.updates.length !== input.through - start
  )
    throw new Error("Incomplete reconstruction range");

  const doc = new Y.Doc({ gc: false });
  const verification = new Y.Doc({ gc: false });
  try {
    const format = input.format ?? "legacy";
    if (format !== "legacy" && format !== "pieces")
      throw new Error("Unsupported content format");
    const structure =
      format === "pieces" ? parsePieceStructure(input.structure) : undefined;
    const names = structure
      ? structure.piece_ids.map((id) => `piece:${id}`)
      : ["body"];
    for (const name of names) doc.getText(name);
    const inputs: Payload[] = [];
    if (input.checkpoint) {
      verifyPayload(input.checkpoint, CHECKPOINT_LIMIT);
      Y.applyUpdate(doc, input.checkpoint.data);
      requireComplete(doc);
      inputs.push(input.checkpoint);
    }
    let sequence = start;
    for (const update of input.updates) {
      if (update.sequence !== ++sequence)
        throw new Error("Missing or reordered update");
      verifyPayload(update, UPDATE_LIMIT);
      Y.applyUpdate(doc, update.data);
      inputs.push(update);
    }
    requireComplete(doc);
    let storedBytes = 0;
    for (const name of doc.share.keys()) {
      const permitted = structure
        ? [...structure.piece_ids, ...structure.deleted_ids].some(
            (id) => name === `piece:${id}`,
          )
        : name === "body";
      if (!permitted) throw new Error("Draft contains an unknown text field");
      const text = doc.getText(name);
      if (
        Object.keys(text.getAttributes()).length ||
        text
          .toDelta()
          .some(
            (part: { insert: unknown; attributes?: unknown }) =>
              typeof part.insert !== "string" || part.attributes,
          )
      )
        throw new Error("Draft must contain plain Markdown text");
      storedBytes += Buffer.byteLength(text.toString(), "utf8");
    }
    const pieces = structure?.piece_ids.map((id) => ({
      id,
      body: doc.getText(`piece:${id}`).toString(),
    }));
    const markdown = pieces
      ? [
          pieces.map((piece) => piece.body).join("\n\n---\n\n"),
          structure?.tags.map((tag) => `[[${tag}]]`).join(" "),
        ]
          .filter(Boolean)
          .join("\n\n")
      : doc.getText("body").toString();
    const bodyBytes = Buffer.byteLength(markdown, "utf8");
    if (bodyBytes > BODY_LIMIT || storedBytes > BODY_LIMIT)
      throw new Error("Markdown exceeds 512 KiB");
    const data = Y.encodeStateAsUpdate(doc);
    if (data.byteLength > CHECKPOINT_LIMIT)
      throw new Error("Checkpoint exceeds 16 MiB");
    verifyCoverage(inputs, data);
    for (const name of doc.share.keys()) verification.getText(name);
    Y.applyUpdate(verification, data);
    requireComplete(verification);
    if (
      [...doc.share.keys()].some(
        (name) =>
          verification.getText(name).toString() !==
          doc.getText(name).toString(),
      ) ||
      !Buffer.from(Y.encodeStateAsUpdate(verification)).equals(data)
    )
      throw new Error("Checkpoint reconstruction mismatch");
    return {
      protocol: 1,
      generation: 1,
      through: input.through,
      data,
      digest: sha256(data),
      markdown,
      markdownDigest: sha256(markdown),
      bodyBytes,
      format,
      ...(structure ? { structure, pieces, tags: structure.tags } : {}),
    };
  } finally {
    doc.destroy();
    verification.destroy();
  }
}
