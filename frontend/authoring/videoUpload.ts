/// <reference types="vite/client" />
import workerUrl from "./videoUpload.worker.ts?worker&url";

export type PreparedVideo = {
  avc: File;
  av1?: File;
  width: number;
  height: number;
};
export type VideoWorkerResponse =
  | { kind: "progress"; message: string }
  | { kind: "error"; message: string }
  | {
      kind: "result";
      avc: ArrayBuffer;
      av1?: ArrayBuffer;
      width: number;
      height: number;
    };

export async function prepareVideo(
  file: File,
  signal: AbortSignal,
  onProgress: (message: string) => void,
): Promise<PreparedVideo> {
  if (file.size <= 0 || file.size > 500_000_000)
    throw new Error("動画は500MB以下にしてください");
  signal.throwIfAborted();
  const worker = new Worker(workerUrl, { type: "module" });
  let abort: () => void = () => {};
  try {
    return await new Promise((resolve, reject) => {
      abort = () =>
        reject(
          new DOMException("動画の追加をキャンセルしました", "AbortError"),
        );
      signal.addEventListener("abort", abort, { once: true });
      worker.onerror = () =>
        reject(
          new Error(
            "動画変換を開始できませんでした。ChromeまたはSafariで試してください",
          ),
        );
      worker.onmessage = (event: MessageEvent<VideoWorkerResponse>) => {
        const message = event.data;
        if (message.kind === "progress") onProgress(message.message);
        if (message.kind === "error") reject(new Error(message.message));
        if (message.kind === "result")
          resolve({
            width: message.width,
            height: message.height,
            avc: new File([message.avc], "video-h264.mp4", {
              type: "video/mp4",
            }),
            ...(message.av1
              ? {
                  av1: new File([message.av1], "video-av1.mp4", {
                    type: "video/mp4",
                  }),
                }
              : {}),
          });
      };
      worker.postMessage(file);
    });
  } finally {
    signal.removeEventListener("abort", abort);
    worker.terminate();
  }
}
