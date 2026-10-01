import type { DraftMetadata } from "./draftSession";

export function draftCoverMetadata(metadata: DraftMetadata): DraftMetadata {
  return metadata.cover_mode === "explicit"
    ? metadata
    : { ...metadata, cover_image_url: null };
}
