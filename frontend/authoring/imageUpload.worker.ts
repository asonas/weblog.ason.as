/// <reference lib="webworker" />

import encode from "@jsquash/webp/encode";

type Request = {
  file: File;
  dimensions: { width: number; height: number };
  lossless: boolean;
};

self.addEventListener("message", async (event: MessageEvent<Request>) => {
  try {
    const { file, dimensions, lossless } = event.data;
    const bitmap = await createImageBitmap(file, {
      imageOrientation: "from-image",
      resizeWidth: dimensions.width,
      resizeHeight: dimensions.height,
      resizeQuality: "high",
    });
    try {
      const canvas = new OffscreenCanvas(dimensions.width, dimensions.height);
      const context = canvas.getContext("2d");
      if (!context) throw new Error("画像を処理できませんでした");
      context.drawImage(bitmap, 0, 0, dimensions.width, dimensions.height);
      const imageData = context.getImageData(
        0,
        0,
        dimensions.width,
        dimensions.height,
      );
      const buffer = await encode(
        imageData,
        lossless ? { lossless: 1 } : { quality: 82 },
      );
      self.postMessage({ ok: true, buffer }, { transfer: [buffer] });
    } finally {
      bitmap.close();
    }
  } catch (error) {
    self.postMessage({
      ok: false,
      error:
        error instanceof Error ? error.message : "画像を変換できませんでした",
    });
  }
});
