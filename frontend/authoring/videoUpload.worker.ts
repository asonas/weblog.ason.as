import {
  ALL_FORMATS,
  BlobSource,
  BufferTarget,
  Conversion,
  canEncodeAudio,
  canEncodeVideo,
  Input,
  Mp4OutputFormat,
  Output,
  Quality,
} from "mediabunny";
import type { VideoWorkerResponse } from "./videoUpload";

function send(message: VideoWorkerResponse, transfer: Transferable[] = []) {
  postMessage(message, { transfer });
}

globalThis.onmessage = async (event: MessageEvent<File>) => {
  const file = event.data;
  const input = new Input({
    source: new BlobSource(file),
    formats: ALL_FORMATS,
  });
  try {
    if (file.size <= 0 || file.size > 500_000_000)
      throw new Error("動画は500MB以下にしてください");
    const video = await input.getPrimaryVideoTrack();
    if (!video) throw new Error("動画の映像を読み取れませんでした");
    const duration = await input.computeDuration();
    if (!Number.isFinite(duration) || duration <= 0 || duration > 60.1)
      throw new Error("動画は60秒以下にしてください");
    const config = await video.getDecoderConfig();
    if (
      ["pq", "hlg", "smpte2084", "arib-std-b67"].includes(
        String(config?.colorSpace?.transfer ?? ""),
      )
    )
      throw new Error(
        "HDR動画にはまだ対応していません。SDRで書き出した動画を選んでください",
      );
    if (!(await video.canDecode()))
      throw new Error(
        "このブラウザでは元動画を読み取れません。ChromeまたはSafariで試してください",
      );
    const audio = await input.getPrimaryAudioTrack();
    if (
      audio &&
      audio.codec !== "aac" &&
      (!(await audio.canDecode()) || !(await canEncodeAudio("aac")))
    )
      throw new Error("このブラウザでは動画の音声を変換できません");
    const scale = Math.min(
      1,
      1080 / Math.min(video.displayWidth, video.displayHeight),
      1920 / Math.max(video.displayWidth, video.displayHeight),
    );
    const width = Math.max(2, Math.floor((video.displayWidth * scale) / 2) * 2);
    const height = Math.max(
      2,
      Math.floor((video.displayHeight * scale) / 2) * 2,
    );
    if (
      !(await canEncodeVideo("avc", {
        width,
        height,
        quality: new Quality({ bitrate: 4_500_000 }),
      }))
    )
      throw new Error(
        "このブラウザでは配信用動画を生成できません。ChromeまたはSafariで試してください",
      );
    const supportsAv1 = await canEncodeVideo("av1", {
      width,
      height,
      quality: new Quality({ bitrate: 2_300_000 }),
    });
    async function encode(codec: "avc" | "av1") {
      const target = new BufferTarget();
      const output = new Output({
        target,
        format: new Mp4OutputFormat({ fastStart: "in-memory" }),
      });
      const conversion = await Conversion.init({
        input,
        output,
        tracks: "primary",
        video: {
          codec,
          width,
          height,
          fit: "contain",
          frameRate: 30,
          quality: new Quality({
            bitrate: codec === "av1" ? 2_300_000 : 4_500_000,
          }),
          keyFrameInterval: 2,
          forceTranscode: true,
          allowRotationMetadata: false,
        },
        audio: { codec: "aac" },
      });
      if (!conversion.isValid || conversion.discardedTracks.length) {
        await conversion.cancel();
        throw new Error("映像と音声を維持して変換できませんでした");
      }
      let last = 0;
      conversion.onProgress = (value) => {
        if (performance.now() - last < 200 && value < 1) return;
        last = performance.now();
        send({
          kind: "progress",
          message: `動画を変換中… ${codec === "avc" ? "H.264" : "AV1"} ${Math.round(value * 100)}%`,
        });
      };
      await conversion.execute();
      if (!target.buffer || target.buffer.byteLength > 50 * 1024 * 1024)
        throw new Error("配信用動画を50MB以下に変換できませんでした");
      return target.buffer;
    }
    const avc = await encode("avc");
    const av1 = supportsAv1 ? await encode("av1") : undefined;
    send(
      { kind: "result", avc, av1, width, height, duration },
      av1 ? [avc, av1] : [avc],
    );
  } catch (error) {
    send({
      kind: "error",
      message:
        error instanceof Error ? error.message : "動画を変換できませんでした",
    });
  } finally {
    input.dispose();
  }
};
