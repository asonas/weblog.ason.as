import type { DraftMetadata } from "./draftSession";

export function draftMetadataForTitle(
  title: string,
): Pick<DraftMetadata, "title" | "page_type" | "page_date"> {
  const date = title.trim();
  const isDate = /^\d{4}-\d{2}-\d{2}$/.test(date);
  return {
    title,
    page_type: isDate ? "date" : "named",
    page_date: isDate ? date : "",
  };
}

export function hasCustomDiaryTitle(metadata: DraftMetadata): boolean {
  return (
    metadata.page_type === "date" &&
    metadata.title.trim() !== metadata.page_date
  );
}
