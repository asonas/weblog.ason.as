import { reconstructDraft } from "./reconstruct.js";

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Invalid stored record");
  return Object.fromEntries(Object.entries(value));
}

function integer(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0)
    throw new Error("Invalid stored sequence or format");
  return value;
}

function payload(value: Record<string, unknown>, limit: number) {
  if (
    typeof value.data !== "string" ||
    value.data.length > Math.ceil(limit / 3) * 4 ||
    typeof value.digest !== "string"
  )
    throw new Error("Invalid stored payload");
  const data = Buffer.from(value.data, "base64");
  if (data.toString("base64") !== value.data)
    throw new Error("Invalid stored encoding");
  return { data, digest: value.digest };
}

export function reconstructStoredDraft(value: unknown) {
  const input = record(value);
  if (typeof input.article_id !== "string" || !Array.isArray(input.updates))
    throw new Error("Invalid stored job");
  const checkpoint =
    input.checkpoint == null ? undefined : record(input.checkpoint);
  const result = reconstructDraft({
    protocol: integer(input.protocol),
    generation: integer(input.generation),
    through: integer(input.through),
    checkpoint: checkpoint
      ? {
          ...payload(checkpoint, 16 * 1024 * 1024),
          through: integer(checkpoint.through),
        }
      : undefined,
    updates: input.updates.map((value: unknown) => {
      const update = record(value);
      return {
        ...payload(update, 2 * 1024 * 1024),
        sequence: integer(update.sequence),
      };
    }),
  });
  return {
    ...result,
    article_id: input.article_id,
    data: Buffer.from(result.data).toString("base64"),
  };
}
