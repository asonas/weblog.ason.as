export const PENDING_DRAFT_FORMAT_VERSION = 1;
export const PENDING_DRAFT_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;

export type PendingDraft = {
  formatVersion: typeof PENDING_DRAFT_FORMAT_VERSION;
  pageKey: string;
  pageId: string | null;
  baseUpdatedAt: string;
  editVersion: number;
  title: string;
  body: string;
  selection: { anchor: number; head: number };
  scroll: { anchorText: string; ratio: number };
  createdAt: string;
  expiresAt: string;
};

function storageKey(pageKey: string): string {
  return `weblog:pending-draft:${pageKey}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isPendingDraft(value: unknown): value is PendingDraft {
  if (!isRecord(value) || !isRecord(value.selection) || !isRecord(value.scroll))
    return false;
  return (
    value.formatVersion === PENDING_DRAFT_FORMAT_VERSION &&
    typeof value.pageKey === "string" &&
    (typeof value.pageId === "string" || value.pageId === null) &&
    typeof value.baseUpdatedAt === "string" &&
    Number.isSafeInteger(value.editVersion) &&
    typeof value.title === "string" &&
    typeof value.body === "string" &&
    Number.isSafeInteger(value.selection.anchor) &&
    Number.isSafeInteger(value.selection.head) &&
    typeof value.scroll.anchorText === "string" &&
    typeof value.scroll.ratio === "number" &&
    Number.isFinite(value.scroll.ratio) &&
    typeof value.createdAt === "string" &&
    typeof value.expiresAt === "string"
  );
}

export function readPendingDraft(
  storage: Storage,
  pageKey: string,
  now = new Date(),
): PendingDraft | null {
  const key = storageKey(pageKey);
  const serialized = storage.getItem(key);
  if (!serialized) return null;
  try {
    const value: unknown = JSON.parse(serialized);
    if (!isPendingDraft(value) || value.pageKey !== pageKey) {
      storage.removeItem(key);
      return null;
    }
    if (new Date(value.expiresAt).getTime() <= now.getTime()) {
      storage.removeItem(key);
      return null;
    }
    return value;
  } catch {
    storage.removeItem(key);
    return null;
  }
}

export function writePendingDraft(storage: Storage, draft: PendingDraft): void {
  storage.setItem(storageKey(draft.pageKey), JSON.stringify(draft));
}

export function clearPendingDraftThrough(
  storage: Storage,
  pageKey: string,
  savedVersion: number,
): void {
  const pending = readPendingDraft(storage, pageKey);
  if (pending && pending.editVersion <= savedVersion)
    storage.removeItem(storageKey(pageKey));
}
