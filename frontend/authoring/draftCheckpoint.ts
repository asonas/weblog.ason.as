export type CheckpointChunk = {
  through: number;
  digest: string;
  chunks: number;
  position: number;
  data: string;
};

export type CheckpointDownload = {
  through: number;
  digest: string;
  chunks: number;
  data: Uint8Array[];
};

function decode(value: string): Uint8Array {
  const binary = atob(value);
  const data = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  let canonical = "";
  for (const byte of data) canonical += String.fromCharCode(byte);
  if (btoa(canonical) !== value)
    throw new Error("チェックポイントの符号化が不正です。");
  return data;
}

async function sha256(data: Uint8Array): Promise<string> {
  const buffer = await crypto.subtle.digest("SHA-256", new Uint8Array(data));
  return Array.from(new Uint8Array(buffer), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

export async function acceptCheckpointChunk(
  current: CheckpointDownload | undefined,
  chunk: CheckpointChunk,
  cursor: number,
  highWater: number,
): Promise<{ download?: CheckpointDownload; binary?: Uint8Array }> {
  const download = current || {
    through: chunk.through,
    digest: chunk.digest,
    chunks: chunk.chunks,
    data: [],
  };
  if (
    chunk.through !== download.through ||
    chunk.digest !== download.digest ||
    chunk.chunks !== download.chunks ||
    chunk.position !== download.data.length ||
    chunk.chunks < 1 ||
    chunk.chunks > 64 ||
    chunk.through <= cursor ||
    chunk.through > highWater
  )
    throw new Error("チェックポイントの構成が一致しません。");
  download.data.push(decode(chunk.data));
  if (download.data.length < download.chunks) return { download };

  const size = download.data.reduce((sum, part) => sum + part.length, 0);
  const binary = new Uint8Array(size);
  let offset = 0;
  for (const part of download.data) {
    binary.set(part, offset);
    offset += part.length;
  }
  if ((await sha256(binary)) !== download.digest)
    throw new Error("チェックポイントの内容が一致しません。");
  return { binary };
}
