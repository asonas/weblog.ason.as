import { createHash } from "node:crypto";
import * as Y from "yjs";

const BODY_LIMIT = 512 * 1024;
const UPDATE_LIMIT = 2 * 1024 * 1024;
const CHECKPOINT_LIMIT = 16 * 1024 * 1024;

type Payload = { data: Uint8Array; digest: string };
export type ReconstructionInput = {
  protocol: number;
  generation: number;
  through: number;
  checkpoint?: Payload & { through: number };
  updates: (Payload & { sequence: number })[];
};

function sha256(data: Uint8Array | string): string {
  return createHash("sha256").update(data).digest("hex");
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
    const body = doc.getText("body");
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
    if (
      doc.share.size !== 1 ||
      Object.keys(body.getAttributes()).length ||
      body
        .toDelta()
        .some(
          (part: { insert: unknown; attributes?: unknown }) =>
            typeof part.insert !== "string" || part.attributes,
        )
    )
      throw new Error("Draft must contain plain Markdown text");
    const markdown = body.toString();
    const bodyBytes = Buffer.byteLength(markdown, "utf8");
    if (bodyBytes > BODY_LIMIT) throw new Error("Markdown exceeds 512 KiB");
    const data = Y.encodeStateAsUpdate(doc);
    if (data.byteLength > CHECKPOINT_LIMIT)
      throw new Error("Checkpoint exceeds 16 MiB");
    verifyCoverage(inputs, data);
    verification.getText("body");
    Y.applyUpdate(verification, data);
    requireComplete(verification);
    if (
      verification.getText("body").toString() !== markdown ||
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
    };
  } finally {
    doc.destroy();
    verification.destroy();
  }
}
