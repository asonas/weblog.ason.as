/// <reference types="vite/client" />

import {
  type ImageDimensions,
  imageDimensions,
  MAX_IMAGE_PIXELS,
  MAX_LONG_EDGE,
  MAX_UPLOAD_BYTES,
  resizedDimensions,
} from "./imageMetadata";
import imageUploadWorkerUrl from "./imageUpload.worker.ts?worker&url";

const SUPPORTED_TYPES = new Set([
  "image/gif",
  "image/jpeg",
  "image/png",
  "image/webp",
]);

export type PreparedImage = { file: File; converted: boolean };

type WorkerSuccess = { ok: true; buffer: ArrayBuffer };
type WorkerFailure = { ok: false; error: string };

function webpName(name: string): string {
  return `${name.replace(/\.[^.]+$/, "") || "image"}.webp`;
}

async function encodeWebp(
  file: File,
  dimensions: ImageDimensions,
): Promise<File> {
  const worker = new Worker(imageUploadWorkerUrl, { type: "module" });
  try {
    const response = await new Promise<WorkerSuccess | WorkerFailure>(
      (resolve, reject) => {
        worker.addEventListener(
          "message",
          (event: MessageEvent<WorkerSuccess | WorkerFailure>) =>
            resolve(event.data),
          { once: true },
        );
        worker.addEventListener(
          "error",
          () => reject(new Error("画像変換ワーカーを起動できませんでした")),
          { once: true },
        );
        worker.postMessage({
          file,
          dimensions,
          lossless: file.type === "image/png",
        });
      },
    );
    if (!response.ok) throw new Error(response.error);
    return new File([response.buffer], webpName(file.name), {
      type: "image/webp",
    });
  } finally {
    worker.terminate();
  }
}

export async function prepareImage(file: File): Promise<PreparedImage> {
  if (!SUPPORTED_TYPES.has(file.type))
    throw new Error("JPEG、PNG、GIF、WebPの画像を選んでください");
  if (file.size <= 0 || file.size > MAX_UPLOAD_BYTES)
    throw new Error("画像は25MB以下にしてください");

  const buffer = await file.arrayBuffer();
  const dimensions = imageDimensions(buffer, file.type);
  if (!dimensions || dimensions.width <= 0 || dimensions.height <= 0)
    throw new Error("画像の寸法を読み取れませんでした");
  if (dimensions.width * dimensions.height > MAX_IMAGE_PIXELS)
    throw new Error("画像の解像度は80メガピクセル以下にしてください");
  if (file.type === "image/gif") return { file, converted: false };
  if (
    file.type === "image/webp" &&
    Math.max(dimensions.width, dimensions.height) <= MAX_LONG_EDGE
  ) {
    return { file, converted: false };
  }

  const resized = resizedDimensions(dimensions);
  const converted = await encodeWebp(file, resized);
  const resizedRequired =
    Math.max(dimensions.width, dimensions.height) > MAX_LONG_EDGE;
  if (!resizedRequired && converted.size > file.size * 0.95)
    return { file, converted: false };
  return { file: converted, converted: true };
}
