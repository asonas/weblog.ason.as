import * as Y from "yjs";
import {
  acceptCheckpointChunk,
  type CheckpointChunk,
  type CheckpointDownload,
} from "./draftCheckpoint";
import { mergeLocalDraft } from "./draftLocalMerge";

export const DRAFT_BODY_LIMIT = 512 * 1024;
const LOCAL_ORIGIN = "local-input";
const REMOTE_ORIGIN = "server";
const UPLOAD_CHUNK_BYTES = 256 * 1024;
export type DraftMetadata = {
  title: string;
  page_type: string;
  page_date: string;
  cover_mode: string;
  cover_image_url: string | null;
};
type Field = keyof DraftMetadata;
export function draftRoute(metadata: DraftMetadata): string {
  return metadata.title;
}
type VersionedMetadata = Record<
  Field,
  { value: string | null; revision: number }
>;
type Changes = Partial<
  Record<Field, { value: string | null; expected_revision: number }>
>;
type MetadataConflicts = Partial<VersionedMetadata>;
type Pending = { id: string; data: Uint8Array };
type Flight = {
  protocol: number;
  generation: number;
  update_id: string;
  data: string;
  digest: string;
  body_bytes: number;
  metadata: Changes;
  included: string[];
};
export type SavedDraft = {
  state: Uint8Array;
  metadata: DraftMetadata;
  serverMetadata: VersionedMetadata;
  pending: Pending[];
  cursor: number;
  flight?: Flight;
  conflicts?: MetadataConflicts;
  tabConflicts?: Partial<Record<Field, (string | null)[]>>;
};
type Page = {
  protocol: number;
  generation: number;
  metadata: VersionedMetadata;
  through: number;
  cursor: number;
  updates: { sequence: number; digest: string; data: string }[];
  checkpoint?: CheckpointChunk;
};
type Receipt = {
  update_id: string;
  digest: string;
  sequence: number;
  metadata: VersionedMetadata;
};
type UploadManifest = {
  update_id: string;
  digest: string;
  chunks: number;
};
export type PublicationConfirmation = {
  protocol: number;
  generation: number;
  head: number;
  metadata_revisions: Record<Field, number>;
  content_hash: string;
  article_state: "draft" | "public" | "unpublished_changes";
  rename?: {
    revision: number;
    from: string;
    to: string;
    references: Array<{
      article_id: string;
      version_id: string;
      title: string;
    }>;
  } | null;
};
type PublicationRequest = PublicationConfirmation & { request_id: string };
type PublicationJob = {
  id: string;
  dispatch?: {
    id: string;
    status: "queued" | "running" | "completed" | "failed";
    error?: string;
  };
  status:
    | "accepted"
    | "unchanged"
    | "completed"
    | "superseded"
    | "needs_attention";
  error?: string;
  stages?: Array<{
    stage: string;
    status: string;
    attempts: number;
    error?: string;
  }>;
};

const DEFAULT_METADATA: DraftMetadata = {
  title: "",
  page_type: "named",
  page_date: "",
  cover_mode: "auto",
  cover_image_url: null,
};
const FIELDS: Field[] = [
  "title",
  "page_type",
  "page_date",
  "cover_mode",
  "cover_image_url",
];

function initialServerMetadata(): VersionedMetadata {
  return {
    title: { value: "", revision: 0 },
    page_type: { value: "named", revision: 0 },
    page_date: { value: "", revision: 0 },
    cover_mode: { value: "auto", revision: 0 },
    cover_image_url: { value: null, revision: 0 },
  };
}

function encode(data: Uint8Array): string {
  let binary = "";
  for (const byte of data) binary += String.fromCharCode(byte);
  return btoa(binary);
}
function decode(data: string): Uint8Array {
  return Uint8Array.from(atob(data), (character) => character.charCodeAt(0));
}
async function digest(data: Uint8Array): Promise<string> {
  const buffer = await crypto.subtle.digest("SHA-256", new Uint8Array(data));
  return Array.from(new Uint8Array(buffer), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

async function openLocalDatabase(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open("weblog-working-drafts-v1", 1);
    request.onupgradeneeded = () => request.result.createObjectStore("drafts");
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    request.onblocked = () =>
      reject(
        new Error(
          "端末内の保存領域を開けません。他の編集タブを確認してください。",
        ),
      );
  });
}

function localRecord(
  db: IDBDatabase,
  id: string,
  value?: SavedDraft,
  base?: SavedDraft,
): Promise<SavedDraft | undefined> {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(
      "drafts",
      value ? "readwrite" : "readonly",
    );
    const store = transaction.objectStore("drafts");
    const request = store.get(id);
    let result: SavedDraft | undefined;
    request.onsuccess = () => {
      try {
        const stored: SavedDraft | undefined = request.result;
        if (stored) {
          stored.metadata = { ...DEFAULT_METADATA, ...stored.metadata };
          stored.serverMetadata = {
            ...initialServerMetadata(),
            ...stored.serverMetadata,
          };
        }
        result =
          value && base && stored
            ? mergeLocalDraft(base, value, stored)
            : value || stored;
        if (value) store.put(result, id);
      } catch (error) {
        transaction.abort();
        reject(error);
      }
    };
    transaction.oncomplete = () => resolve(result);
    transaction.onabort = () =>
      reject(transaction.error || new Error("端末内保存に失敗しました"));
    transaction.onerror = () => reject(transaction.error);
  });
}

export type LocalDraftSummary = {
  id: string;
  metadata: DraftMetadata;
  cursor: number;
  pending: boolean;
  contentHash: string;
};

// Read persisted summaries without starting synchronization or opening editors.
export async function readLocalDraftSummaries(): Promise<LocalDraftSummary[]> {
  const db = await openLocalDatabase();
  try {
    return await new Promise((resolve, reject) => {
      const transaction = db.transaction("drafts", "readonly");
      const request = transaction.objectStore("drafts").openCursor();
      const summaries: Promise<LocalDraftSummary>[] = [];
      request.onsuccess = () => {
        const cursor = request.result;
        if (!cursor) return;
        const saved: SavedDraft = cursor.value;
        const summary = {
          id: String(cursor.key),
          metadata: saved.metadata,
          cursor: saved.cursor,
          pending: Boolean(
            saved.pending.length ||
              saved.flight ||
              Object.keys(saved.conflicts || {}).length ||
              Object.keys(saved.tabConflicts || {}).length ||
              Object.entries(saved.metadata).some(
                ([key, value]) =>
                  saved.serverMetadata[key as Field]?.value !== value,
              ),
          ),
        };
        const doc = new Y.Doc();
        try {
          Y.applyUpdate(doc, saved.state);
          const content = new TextEncoder().encode(
            JSON.stringify([
              doc.getText("body").toString().replaceAll("\r\n", "\n"),
              saved.metadata.title.trim(),
              saved.metadata.page_type,
              saved.metadata.cover_mode,
              saved.metadata.cover_mode === "explicit"
                ? saved.metadata.cover_image_url
                : null,
              ...(saved.metadata.page_type === "date" &&
              saved.metadata.page_date
                ? [saved.metadata.page_date]
                : []),
            ]),
          );
          summaries.push(
            digest(content).then((contentHash) => ({
              ...summary,
              contentHash,
            })),
          );
        } catch (error) {
          transaction.abort();
          reject(error);
          return;
        } finally {
          doc.destroy();
        }
        cursor.continue();
      };
      transaction.oncomplete = () => resolve(Promise.all(summaries));
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(transaction.error);
    });
  } finally {
    db.close();
  }
}

class DraftRequestError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

export class DraftSession extends EventTarget {
  readonly doc = new Y.Doc();
  readonly body = this.doc.getText("body");
  readonly undo = new Y.UndoManager(this.body, {
    trackedOrigins: new Set([LOCAL_ORIGIN]),
  });
  metadata: DraftMetadata = { ...DEFAULT_METADATA };
  localStatus = "読み込み中";
  serverStatus = "未同期";
  error = "";
  private serverMetadata = initialServerMetadata();
  private conflicts: MetadataConflicts = {};
  private tabConflicts: SavedDraft["tabConflicts"] = {};
  private baseline?: SavedDraft;
  private failedBase?: SavedDraft;
  private channel?: BroadcastChannel;
  private pending: Pending[] = [];
  private cursor = 0;
  private flight?: Flight;
  private database?: IDBDatabase;
  private writes: Promise<void> = Promise.resolve();
  private revision = 0;
  private persistedRevision = 0;
  private isSyncing = false;
  isPublishing = false;
  publicationStatus = "";
  pendingPublication?: PublicationRequest;
  pendingOutputs?: string;
  isRetryingOutputs = false;
  private isClosed = false;
  private isComposing = false;
  private isBackgroundPaused = false;
  private retryCount = 0;
  private timer?: ReturnType<typeof setTimeout>;
  private continuousTimer?: ReturnType<typeof setTimeout>;
  private retryTimer?: ReturnType<typeof setTimeout>;
  private pollTimer?: ReturnType<typeof setInterval>;

  private readonly refresh = () => {
    if (document.visibilityState === "visible" && !this.isBackgroundPaused)
      void this.sync();
  };

  private constructor(
    readonly id: string,
    private readonly csrf: () => Promise<string>,
  ) {
    super();
  }

  static async open(
    id: string,
    csrf: () => Promise<string>,
    isNew = false,
  ): Promise<DraftSession> {
    if (
      !/^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/.test(
        id,
      )
    ) {
      throw new Error("下書きのIDが不正です。");
    }
    const session = new DraftSession(id, csrf);
    session.pendingOutputs =
      sessionStorage.getItem(`draft-outputs:${id}`) || undefined;
    const pendingPublication = sessionStorage.getItem(
      `draft-publication:${id}`,
    );
    if (pendingPublication) {
      session.pendingPublication = JSON.parse(pendingPublication);
      session.publicationStatus = "公開処理の結果を再確認してください";
    }
    let saved: SavedDraft | undefined;
    try {
      session.database = await openLocalDatabase();
      saved = await localRecord(session.database, id);
      if (saved) {
        Y.applyUpdate(session.doc, saved.state, REMOTE_ORIGIN);
        session.metadata = saved.metadata;
        session.serverMetadata = saved.serverMetadata;
        session.pending = saved.pending;
        session.cursor = saved.cursor;
        session.flight = saved.flight;
        session.conflicts = saved.conflicts || {};
        session.tabConflicts = saved.tabConflicts || {};
      }
      session.baseline = session.snapshot();
      session.localStatus = saved
        ? "端末に保存済み"
        : "入力すると下書き保存します";
    } catch (error) {
      session.database?.close();
      throw error;
    }
    try {
      await navigator.locks.request(`draft-sync:${id}`, async () => {
        await session.readShared();
        await session.catchUp(isNew || Boolean(saved));
      });
    } catch (error) {
      if (!saved && !isNew) {
        session.database?.close();
        throw error;
      }
      session.error =
        error instanceof Error ? error.message : "下書きを読み込めませんでした";
    }
    session.doc.on("update", (update: Uint8Array, origin: unknown) => {
      if (origin === REMOTE_ORIGIN) return;
      session.pending.push({ id: crypto.randomUUID(), data: update });
      session.changed();
    });
    if (session.hasPendingChanges()) session.schedule();
    session.pollTimer = setInterval(session.refresh, 10_000);
    session.channel = new BroadcastChannel(`draft:${id}`);
    session.channel.onmessage = () => {
      if (!session.isSyncing && !session.isComposing && !session.isPublishing)
        void session.readShared().catch((error: unknown) => {
          session.error =
            error instanceof Error
              ? error.message
              : "タブ間の同期に失敗しました";
          session.emit();
        });
    };
    window.addEventListener("online", session.refresh);
    window.addEventListener("focus", session.refresh);
    document.addEventListener("visibilitychange", session.refresh);
    return session;
  }

  private hasPendingChanges() {
    return Boolean(
      this.pending.length ||
        this.flight ||
        FIELDS.some(
          (field) => this.metadata[field] !== this.serverMetadata[field].value,
        ),
    );
  }

  private emit() {
    this.dispatchEvent(new Event("change"));
  }

  private async request<T>(
    suffix: string,
    method = "GET",
    payload?: unknown,
  ): Promise<T> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);
    try {
      const response = await fetch(
        `/api/authoring/drafts/${encodeURIComponent(this.id)}${suffix}`,
        {
          method,
          cache: "no-store",
          credentials: "same-origin",
          signal: controller.signal,
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": await this.csrf(),
          },
          body: payload === undefined ? undefined : JSON.stringify(payload),
        },
      );
      if (!response.ok) {
        const result = await response.json().catch(() => ({}));
        throw new DraftRequestError(
          result.error || `下書きの通信に失敗しました (${response.status})`,
          response.status,
        );
      }
      return await response.json();
    } catch (error) {
      if (error instanceof DraftRequestError) throw error;
      if (!(error instanceof TypeError) && !controller.signal.aborted)
        throw error;
      throw new DraftRequestError(
        "通信できません。本文を保持して再接続を待っています。",
        0,
      );
    } finally {
      clearTimeout(timeout);
    }
  }

  private async catchUp(allowMissing = false) {
    let through: number | undefined;
    let checkpoint: CheckpointDownload | undefined;
    while (true) {
      const query = new URLSearchParams({
        protocol: "1",
        generation: "1",
        cursor: String(this.cursor),
      });
      if (through !== undefined) query.set("through", String(through));
      if (checkpoint) {
        query.set("checkpoint_through", String(checkpoint.through));
        query.set("checkpoint_position", String(checkpoint.data.length));
      }
      let page: Page;
      try {
        page = await this.request<Page>(`?${query}`);
      } catch (error) {
        if (
          error instanceof DraftRequestError &&
          error.status === 404 &&
          allowMissing &&
          this.cursor === 0
        )
          return;
        if (error instanceof DraftRequestError && error.status === 410) {
          through = undefined;
          checkpoint = undefined;
          continue;
        }
        throw error;
      }
      if (page.generation !== 1 || page.protocol !== 1)
        throw new Error("保存形式が対応していません。本文を退避してください。");
      if (this.isComposing || this.isClosed) return;
      through = page.through;
      let appliedCheckpoint = false;
      if (page.checkpoint) {
        if (page.cursor !== this.cursor || page.updates.length)
          throw new Error("チェックポイントの構成が一致しません。");
        const accepted = await acceptCheckpointChunk(
          checkpoint,
          page.checkpoint,
          this.cursor,
          through,
        );
        checkpoint = accepted.download;
        if (!accepted.binary) continue;
        if (this.isComposing || this.isClosed) return;
        Y.applyUpdate(this.doc, accepted.binary, REMOTE_ORIGIN);
        this.cursor = page.checkpoint.through;
        checkpoint = undefined;
        appliedCheckpoint = true;
      } else if (checkpoint) {
        throw new Error("チェックポイントが不足しています。");
      }
      for (const update of page.updates) {
        const binary = decode(update.data);
        if (
          (await digest(binary)) !== update.digest ||
          update.sequence !== this.cursor + 1
        )
          throw new Error(
            "同期データが一致しません。本文を保持して同期を停止しました。",
          );
        if (this.isComposing || this.isClosed) return;
        Y.applyUpdate(this.doc, binary, REMOTE_ORIGIN);
        this.cursor = update.sequence;
      }
      if (
        (!appliedCheckpoint && page.cursor !== this.cursor) ||
        (this.cursor < through &&
          page.updates.length === 0 &&
          !appliedCheckpoint)
      )
        throw new Error("同期データが不足しています。");
      if (!this.flight) this.mergeMetadata(page.metadata);
      await this.persist();
      if (this.cursor >= through) break;
    }
    this.serverStatus = this.metadataConflicts.length
      ? "設定の競合を確認してください"
      : this.hasPendingChanges()
        ? "未送信の変更あり"
        : "サーバーに保存済み";
  }

  private mergeMetadata(incoming: VersionedMetadata) {
    incoming = { ...initialServerMetadata(), ...incoming };
    for (const field of FIELDS) {
      const remote = incoming[field];
      const base = this.serverMetadata[field];
      if (remote.revision < base.revision) continue;
      const local = this.metadata[field];
      if (
        (!this.conflicts[field] &&
          !this.tabConflicts?.[field]?.length &&
          local === base.value) ||
        local === remote.value
      ) {
        if (field === "cover_image_url") this.metadata[field] = remote.value;
        else this.metadata[field] = remote.value ?? "";
        this.serverMetadata[field] = remote;
        delete this.conflicts[field];
      } else if (remote.revision > base.revision) {
        this.conflicts[field] = remote;
      }
    }
  }

  get metadataConflicts() {
    return FIELDS.flatMap((field) => {
      const alternative = this.tabConflicts?.[field];
      if (alternative?.length)
        return [
          {
            field,
            local: this.metadata[field],
            remote: alternative[0],
            source: "tab",
          },
        ];
      const conflict = this.conflicts[field];
      return conflict
        ? [
            {
              field,
              local: this.metadata[field],
              remote: conflict.value,
              source: "server",
            },
          ]
        : [];
    });
  }

  resolveMetadata(field: Field, choice: "local" | "remote") {
    const alternatives = this.tabConflicts?.[field];
    if (alternatives?.length && !this.flight) {
      const [value, ...remaining] = alternatives;
      if (choice === "remote") {
        if (field === "cover_image_url") this.metadata[field] = value;
        else this.metadata[field] = value ?? "";
      }
      if (this.tabConflicts) {
        if (remaining.length) this.tabConflicts[field] = remaining;
        else delete this.tabConflicts[field];
      }
      this.changed();
      return;
    }
    const conflict = this.conflicts[field];
    if (!conflict || this.flight) return;
    if (choice === "remote") {
      if (field === "cover_image_url") this.metadata[field] = conflict.value;
      else this.metadata[field] = conflict.value ?? "";
    }
    this.serverMetadata[field] = conflict;
    delete this.conflicts[field];
    this.error = "";
    this.isBackgroundPaused = false;
    this.changed();
  }

  setBody(value: string) {
    if (this.isPublishing) return;
    const old = Array.from(this.body.toString());
    const next = Array.from(value);
    let prefix = 0;
    while (
      prefix < old.length &&
      prefix < next.length &&
      old[prefix] === next[prefix]
    )
      prefix++;
    let suffix = 0;
    while (
      suffix < old.length - prefix &&
      suffix < next.length - prefix &&
      old[old.length - 1 - suffix] === next[next.length - 1 - suffix]
    )
      suffix++;
    const start = old.slice(0, prefix).join("").length;
    const removed = old.slice(prefix, old.length - suffix).join("").length;
    const added = next.slice(prefix, next.length - suffix).join("");
    if (!removed && !added) return;
    this.doc.transact(() => {
      if (removed) this.body.delete(start, removed);
      if (added) this.body.insert(start, added);
    }, LOCAL_ORIGIN);
  }

  setMetadata(values: Partial<DraftMetadata>) {
    if (this.isPublishing) return;
    if (
      values.title !== undefined &&
      this.metadata.page_type === "date" &&
      !this.metadata.page_date &&
      /^\d{4}-\d{2}-\d{2}$/.test(this.metadata.title)
    ) {
      // Older drafts stored the diary date only in the title.
      values = { page_date: this.metadata.title, ...values };
    }
    this.metadata = { ...this.metadata, ...values };
    this.changed();
  }

  setComposing(value: boolean) {
    this.isComposing = value;
    if (!value) this.schedule();
  }

  private changed() {
    this.revision++;
    this.serverStatus = "未送信の変更あり";
    void this.persist().catch(() => {});
    this.schedule();
    this.emit();
  }

  private schedule() {
    if (this.isClosed) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.sync(), 1000);
    this.continuousTimer ??= setTimeout(() => void this.sync(), 5000);
  }

  private snapshot(): SavedDraft {
    return structuredClone({
      state: Y.encodeStateAsUpdate(this.doc),
      metadata: this.metadata,
      serverMetadata: this.serverMetadata,
      pending: this.pending,
      cursor: this.cursor,
      flight: this.flight,
      conflicts: this.conflicts,
      tabConflicts: this.tabConflicts,
    });
  }

  private adopt(saved: SavedDraft) {
    Y.applyUpdate(this.doc, saved.state, REMOTE_ORIGIN);
    this.metadata = saved.metadata;
    this.serverMetadata = saved.serverMetadata;
    this.pending = saved.pending;
    this.cursor = saved.cursor;
    this.flight = saved.flight;
    this.conflicts = saved.conflicts || {};
    this.tabConflicts = saved.tabConflicts || {};
  }

  private async readShared() {
    await this.writes;
    if (!this.database || this.isClosed || this.isComposing) return;
    const base = this.baseline || this.snapshot();
    const saved = await localRecord(this.database, this.id);
    if (!saved || this.isComposing || this.isClosed) return;
    const merged = mergeLocalDraft(base, this.snapshot(), saved);
    this.adopt(merged);
    this.baseline = structuredClone(merged);
    this.emit();
  }

  private persist(): Promise<void> {
    const revision = this.revision;
    const value = this.snapshot();
    const base = this.baseline || value;
    this.baseline = value;
    this.localStatus = "端末に保存中";
    this.writes = this.writes
      .catch(() => {})
      .then(async () => {
        if (!this.database) throw new Error("端末内の保存領域を利用できません");
        try {
          await localRecord(
            this.database,
            this.id,
            value,
            this.failedBase || base,
          );
          this.failedBase = undefined;
        } catch (error) {
          this.failedBase ||= base;
          throw error;
        }
        this.channel?.postMessage(null);
        this.persistedRevision = revision;
        if (revision === this.revision) this.localStatus = "端末に保存済み";
      })
      .catch((error: unknown) => {
        this.localStatus = "端末に保存できません。本文を退避してください";
        this.error =
          error instanceof Error ? error.message : "端末内保存に失敗しました";
        throw error;
      })
      .finally(() => this.emit());
    return this.writes;
  }

  async sync() {
    if (
      this.isSyncing ||
      this.isClosed ||
      this.isComposing ||
      this.isPublishing
    )
      return;
    this.isSyncing = true;
    try {
      await navigator.locks.request(`draft-sync:${this.id}`, async () => {
        if (this.isClosed || this.isComposing) return;
        if (this.failedBase) await this.persist();
        await this.readShared();
        await this.syncLocked();
      });
    } catch (error) {
      this.error =
        error instanceof Error ? error.message : "タブ間の同期に失敗しました";
      this.emit();
    } finally {
      this.isSyncing = false;
    }
  }

  private contentHash() {
    return digest(
      new TextEncoder().encode(
        JSON.stringify([
          this.body.toString().replaceAll("\r\n", "\n"),
          this.metadata.title.trim(),
          this.metadata.page_type,
          this.metadata.cover_mode,
          this.metadata.cover_mode === "explicit"
            ? this.metadata.cover_image_url
            : null,
          ...(this.metadata.page_type === "date" && this.metadata.page_date
            ? [this.metadata.page_date]
            : []),
        ]),
      ),
    );
  }

  async preparePublication(): Promise<PublicationConfirmation> {
    if (this.isComposing || this.isPublishing || this.isClosed)
      throw new Error("入力の確定後に公開してください。");
    this.isPublishing = true;
    this.emit();
    try {
      const seen = await this.contentHash();
      await navigator.locks.request(`draft-sync:${this.id}`, async () => {
        this.isSyncing = true;
        try {
          if (this.failedBase) await this.persist();
          await this.readShared();
          await this.syncLocked();
        } finally {
          this.isSyncing = false;
        }
      });
      if (
        this.error ||
        this.hasPendingChanges() ||
        this.metadataConflicts.length ||
        this.localStatus !== "端末に保存済み"
      )
        throw new Error(
          this.error ||
            "未保存の変更または設定の競合を解決してから公開してください。",
        );
      if (seen !== (await this.contentHash()))
        throw new Error(
          "別の編集が合流しました。本文と設定を確認して、もう一度公開してください。",
        );
      const confirmation = await this.request<PublicationConfirmation>(
        "/publications/prepare",
        "POST",
        {},
      );
      if (
        confirmation.content_hash !== seen ||
        confirmation.head !== this.cursor ||
        FIELDS.some(
          (field) =>
            confirmation.metadata_revisions[field] !==
            this.serverMetadata[field].revision,
        )
      )
        throw new Error(
          "確認中に別の編集が届きました。再同期して内容を確認してください。",
        );
      return confirmation;
    } catch (error) {
      this.cancelPublication();
      throw error;
    }
  }

  cancelPublication() {
    this.isPublishing = false;
    this.emit();
  }

  async publish(confirmation?: PublicationConfirmation) {
    this.isPublishing = true;
    this.emit();
    try {
      if (!this.pendingPublication) {
        if (!confirmation) throw new Error("公開内容を確認してください。");
        this.pendingPublication = {
          ...confirmation,
          request_id: crypto.randomUUID(),
        };
        sessionStorage.setItem(
          `draft-publication:${this.id}`,
          JSON.stringify(this.pendingPublication),
        );
      }
      const accepted = await this.request<PublicationJob>(
        "/publications",
        "POST",
        this.pendingPublication,
      );
      this.publicationStatus =
        accepted.status === "unchanged"
          ? "公開版と同じ内容です"
          : "公開を受け付けました。HTMLを配置中";
      this.emit();
      if (accepted.status !== "unchanged") {
        const job = await this.runPublication(accepted.id);
        if (job.status !== "completed" && job.status !== "superseded")
          throw new Error(job.error || "公開処理を再試行してください。");
        this.publicationStatus =
          job.status === "completed"
            ? "公開が完了しました"
            : "新しい公開操作が優先されました";
        if (
          job.stages?.some(
            (stage) => !["completed", "superseded"].includes(stage.status),
          )
        ) {
          this.pendingOutputs = job.id;
          sessionStorage.setItem(`draft-outputs:${this.id}`, job.id);
          this.publicationStatus =
            "記事の公開が完了しました。フィード・検索の更新を再試行してください。";
        } else {
          this.pendingOutputs = undefined;
          sessionStorage.removeItem(`draft-outputs:${this.id}`);
        }
      }
      this.pendingPublication = undefined;
      sessionStorage.removeItem(`draft-publication:${this.id}`);
    } catch (error) {
      if (error instanceof DraftRequestError && error.status === 409) {
        this.pendingPublication = undefined;
        sessionStorage.removeItem(`draft-publication:${this.id}`);
      }
      this.publicationStatus =
        error instanceof Error
          ? error.message
          : "公開結果を確認できません。再試行してください。";
      throw error;
    } finally {
      this.cancelPublication();
    }
  }

  async webmentionStatus() {
    return this.request<{
      version_id: string;
      targets: string[];
      pending: boolean;
      enabled: boolean;
    }>("/webmentions");
  }

  async sendWebmentions(versionId: string) {
    return this.request<{
      version_id: string;
      targets: string[];
      pending: boolean;
      enabled: boolean;
    }>("/webmentions", "POST", { version_id: versionId });
  }

  async retryOutputs() {
    if (!this.pendingOutputs || this.isRetryingOutputs) return;
    this.isRetryingOutputs = true;
    this.emit();
    try {
      const job = await this.runPublication(this.pendingOutputs);
      if (
        job.stages?.some(
          (stage) => !["completed", "superseded"].includes(stage.status),
        )
      )
        throw new Error(
          "記事は公開済みです。フィード・検索の更新を完了できませんでした。",
        );
      this.pendingOutputs = undefined;
      sessionStorage.removeItem(`draft-outputs:${this.id}`);
      this.publicationStatus = "公開後の更新が完了しました";
    } catch (error) {
      this.publicationStatus =
        error instanceof Error
          ? error.message
          : "公開後の更新を再試行してください";
    } finally {
      this.isRetryingOutputs = false;
      this.emit();
    }
  }

  private async runPublication(versionId: string) {
    let job = await this.request<PublicationJob>(
      `/publications/${versionId}/run`,
      "POST",
      {},
    );
    const dispatchId = job.dispatch?.id;
    if (!dispatchId) return job;
    const deadline = Date.now() + 300_000;
    while (
      job.dispatch?.status === "queued" ||
      job.dispatch?.status === "running"
    ) {
      if (Date.now() >= deadline)
        throw new Error(
          "公開処理は継続中です。しばらくしてから結果を再確認してください。",
        );
      await new Promise((resolve) => setTimeout(resolve, 1000));
      job = await this.request<PublicationJob>(
        `/publications/${versionId}?dispatch_id=${encodeURIComponent(dispatchId)}`,
        "GET",
      );
    }
    if (job.dispatch?.status !== "completed")
      throw new Error(
        job.dispatch?.error || "公開結果を確認できません。再試行してください。",
      );
    return job;
  }

  private async syncLocked() {
    clearTimeout(this.timer);
    clearTimeout(this.continuousTimer);
    clearTimeout(this.retryTimer);
    this.continuousTimer = undefined;
    this.isSyncing = true;
    try {
      await this.writes;
      if (this.persistedRevision !== this.revision) return;
      if (
        new TextEncoder().encode(this.body.toString()).length > DRAFT_BODY_LIMIT
      )
        throw new Error(
          "本文が512 KiBを超えています。端末内には保持していますが、サーバーへは保存できません。",
        );
      if (!this.flight) await this.catchUp(true);
      if (this.isClosed || this.isComposing) return;
      if (this.metadataConflicts.length && !this.flight) return;
      if (this.hasPendingChanges())
        await this.request("", "PUT", { protocol: 1, generation: 1 });
      if (!this.flight) {
        const metadata: Changes = {};
        for (const field of FIELDS) {
          if (this.metadata[field] !== this.serverMetadata[field].value)
            metadata[field] = {
              value: this.metadata[field],
              expected_revision: this.serverMetadata[field].revision,
            };
        }
        if (this.pending.length || Object.keys(metadata).length) {
          const pending = [...this.pending];
          const binary = pending.length
            ? Y.mergeUpdates(pending.map((item) => item.data))
            : new Uint8Array([0, 0]);
          const flight: Flight = {
            protocol: 1,
            generation: 1,
            update_id: crypto.randomUUID(),
            data: encode(binary),
            digest: "",
            body_bytes: new TextEncoder().encode(this.body.toString()).length,
            metadata,
            included: pending.map((item) => item.id),
          };
          flight.digest = await digest(binary);
          this.flight = flight;
          await this.persist();
        }
      }
      if (this.flight) {
        const flight = this.flight;
        this.serverStatus = "サーバーに保存中";
        this.emit();
        let receipt: Receipt;
        try {
          receipt = await this.uploadFlight(flight);
        } catch (error) {
          // Only an explicit metadata rejection proves that this flight was not committed.
          if (
            error instanceof DraftRequestError &&
            error.status === 409 &&
            error.message.startsWith("Metadata conflict:")
          ) {
            this.flight = undefined;
            await this.persist();
            await this.catchUp();
            this.error = "";
            return;
          }
          throw error;
        }
        if (
          receipt.update_id !== flight.update_id ||
          receipt.digest !== flight.digest
        )
          throw new Error("保存応答が一致しません。本文を保持しています。");
        receipt.metadata = { ...initialServerMetadata(), ...receipt.metadata };
        this.pending = this.pending.filter(
          (item) => !flight.included.includes(item.id),
        );
        for (const field of FIELDS) {
          if (
            !flight.metadata[field] &&
            this.metadata[field] === this.serverMetadata[field].value
          ) {
            const value = receipt.metadata[field].value;
            if (field === "cover_image_url") this.metadata[field] = value;
            else this.metadata[field] = value ?? "";
          }
        }
        this.serverMetadata = receipt.metadata;
        this.flight = undefined;
        await this.persist();
      }
      await this.catchUp(true);
      this.error = "";
      this.retryCount = 0;
      this.isBackgroundPaused = false;
    } catch (error) {
      this.serverStatus = "サーバー保存を確認できません";
      this.error =
        error instanceof Error ? error.message : "保存できませんでした";
      const isTransient =
        error instanceof DraftRequestError &&
        (error.status === 0 ||
          error.status === 408 ||
          error.status === 429 ||
          (error.status === 404 &&
            error.message === "Upload manifest not found") ||
          error.status >= 500);
      this.isBackgroundPaused = !isTransient;
      if (isTransient && !this.isClosed) {
        const delay = Math.min(
          30_000,
          1000 * 2 ** Math.min(this.retryCount++, 5),
        );
        this.retryTimer = setTimeout(() => void this.sync(), delay);
      }
    } finally {
      if (
        !this.error &&
        !this.metadataConflicts.length &&
        this.hasPendingChanges()
      )
        this.schedule();
      this.emit();
    }
  }

  private async uploadFlight(flight: Flight): Promise<Receipt> {
    const binary = decode(flight.data);
    const chunks = Math.ceil(binary.byteLength / UPLOAD_CHUNK_BYTES);
    const started = await this.request<UploadManifest | Receipt>(
      "/uploads",
      "POST",
      {
        protocol: flight.protocol,
        generation: flight.generation,
        update_id: flight.update_id,
        digest: flight.digest,
        body_bytes: flight.body_bytes,
        metadata: flight.metadata,
        chunks,
      },
    );
    if ("sequence" in started) return started;
    if (
      started.update_id !== flight.update_id ||
      started.digest !== flight.digest ||
      started.chunks !== chunks
    )
      throw new Error("アップロード応答が一致しません。本文を保持しています。");
    for (let position = 0; position < chunks; position++) {
      const data = binary.slice(
        position * UPLOAD_CHUNK_BYTES,
        (position + 1) * UPLOAD_CHUNK_BYTES,
      );
      await this.request(
        `/uploads/${encodeURIComponent(flight.update_id)}/chunks/${position}`,
        "PUT",
        {
          protocol: flight.protocol,
          generation: flight.generation,
          data: encode(data),
          digest: await digest(data),
        },
      );
    }
    return this.request<Receipt>(
      `/uploads/${encodeURIComponent(flight.update_id)}/commit`,
      "POST",
      { protocol: flight.protocol, generation: flight.generation },
    );
  }

  close() {
    this.isClosed = true;
    this.channel?.close();
    clearTimeout(this.timer);
    clearTimeout(this.continuousTimer);
    clearTimeout(this.retryTimer);
    clearInterval(this.pollTimer);
    window.removeEventListener("online", this.refresh);
    window.removeEventListener("focus", this.refresh);
    document.removeEventListener("visibilitychange", this.refresh);
    void this.writes.finally(() => this.database?.close()).catch(() => {});
  }
}
