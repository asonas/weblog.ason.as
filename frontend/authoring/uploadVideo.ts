import { videoAssetPath } from "./Video";
import { prepareVideo } from "./videoUpload";

export async function uploadVideo(
  file: File,
  csrf: () => Promise<string>,
  signal: AbortSignal,
  onProgress: (message: string) => void,
) {
  const prepared = await prepareVideo(file, signal, onProgress);
  async function request(payload: Record<string, unknown>) {
    const response = await fetch("/api/uploads", {
      method: "POST",
      signal,
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": await csrf(),
      },
      body: JSON.stringify(payload),
    });
    const result = (await response.json()) as {
      error?: string;
      upload_url: string;
      fields: Record<string, string>;
      public_url: string;
    };
    if (!response.ok)
      throw new Error(result.error || "動画をアップロードできませんでした");
    return result;
  }
  async function send(output: File, codec: string) {
    onProgress(`動画をアップロード中… ${codec}`);
    const result = await request({
      content_type: output.type,
      size: output.size,
    });
    const path = videoAssetPath(result.public_url);
    if (!path) throw new Error("動画のURLが不正です");
    const form = new FormData();
    for (const [key, value] of Object.entries(result.fields))
      form.append(key, String(value));
    form.append("file", output);
    const response = await fetch(result.upload_url, {
      method: "POST",
      body: form,
      signal,
    });
    if (!response.ok) throw new Error("動画をS3へ送信できませんでした");
    return path;
  }
  const avc = await send(prepared.avc, "H.264");
  const av1 = prepared.av1 ? await send(prepared.av1, "AV1") : undefined;
  const video = {
    avc,
    av1,
    width: prepared.width,
    height: prepared.height,
    duration: prepared.duration,
  };
  onProgress("動画を素材に登録中…");
  await request({
    action: "register_video",
    name: file.name.slice(0, 255) || "動画",
    ...video,
  });
  signal.throwIfAborted();
  return video;
}
