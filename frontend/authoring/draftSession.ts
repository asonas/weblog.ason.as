import * as Y from "yjs";

export const DRAFT_BODY_LIMIT = 512 * 1024;
const LOCAL_ORIGIN = "local-input";
const REMOTE_ORIGIN = "server";
export type DraftMetadata = {
  title: string;
  page_type: string;
  cover_mode: string;
  cover_image_url: string | null;
};
type Field = keyof DraftMetadata;
type VersionedMetadata = Record<
  Field,
  { value: string | null; revision: number }
>;
type Changes = Partial<
  Record<Field, { value: string | null; expected_revision: number }>
>;
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
type SavedDraft = {
  state: Uint8Array;
  metadata: DraftMetadata;
  serverMetadata: VersionedMetadata;
  pending: Pending[];
  cursor: number;
  flight?: Flight;
};
type Page = {
  protocol: number;
  generation: number;
  metadata: VersionedMetadata;
  through: number;
  cursor: number;
  updates: { sequence: number; digest: string; data: string }[];
};
type Receipt = {
  update_id: string;
  digest: string;
  sequence: number;
  metadata: VersionedMetadata;
};

const DEFAULT_METADATA: DraftMetadata = {
  title: "",
  page_type: "named",
  cover_mode: "auto",
  cover_image_url: null,
};
const FIELDS: Field[] = ["title", "page_type", "cover_mode", "cover_image_url"];

function initialServerMetadata(): VersionedMetadata {
  return {
    title: { value: "", revision: 0 },
    page_type: { value: "named", revision: 0 },
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
): Promise<SavedDraft | undefined> {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(
      "drafts",
      value ? "readwrite" : "readonly",
    );
    const store = transaction.objectStore("drafts");
    const request = value ? store.put(value, id) : store.get(id);
    transaction.oncomplete = () => resolve(value || request.result);
    transaction.onabort = () =>
      reject(transaction.error || new Error("端末内保存に失敗しました"));
    transaction.onerror = () => reject(transaction.error);
  });
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
  private pending: Pending[] = [];
  private cursor = 0;
  private flight?: Flight;
  private database?: IDBDatabase;
  private writes: Promise<void> = Promise.resolve();
  private revision = 0;
  private persistedRevision = 0;
  private isSyncing = false;
  private isClosed = false;
  private timer?: ReturnType<typeof setTimeout>;

  private constructor(
    readonly id: string,
    private readonly csrf: () => string,
  ) {
    super();
  }

  static async open(
    id: string,
    csrf: () => string,
    isNew = false,
  ): Promise<DraftSession> {
    if (
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)
    ) {
      throw new Error("下書きのIDが不正です。");
    }
    const session = new DraftSession(id, csrf);
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
      }
      session.localStatus = saved
        ? "端末に保存済み"
        : "入力すると下書き保存します";
    } catch (error) {
      session.database?.close();
      throw error;
    }
    try {
      await session.catchUp(isNew || Boolean(saved));
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
    const response = await fetch(
      `/api/authoring/drafts/${encodeURIComponent(this.id)}${suffix}`,
      {
        method,
        cache: "no-store",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrf(),
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
    return response.json();
  }

  private async catchUp(allowMissing = false) {
    let through: number | undefined;
    do {
      const query = new URLSearchParams({
        protocol: "1",
        generation: "1",
        cursor: String(this.cursor),
      });
      if (through !== undefined) query.set("through", String(through));
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
        throw error;
      }
      if (page.generation !== 1 || page.protocol !== 1)
        throw new Error("保存形式が対応していません。本文を退避してください。");
      through = page.through;
      for (const update of page.updates) {
        const binary = decode(update.data);
        if (
          (await digest(binary)) !== update.digest ||
          update.sequence !== this.cursor + 1
        )
          throw new Error(
            "同期データが一致しません。本文を保持して同期を停止しました。",
          );
        Y.applyUpdate(this.doc, binary, REMOTE_ORIGIN);
        this.cursor = update.sequence;
      }
      if (
        page.cursor !== this.cursor ||
        (this.cursor < through && page.updates.length === 0)
      )
        throw new Error("同期データが不足しています。");
      for (const field of FIELDS) {
        if (this.metadata[field] === this.serverMetadata[field].value) {
          const value = page.metadata[field].value;
          if (field === "cover_image_url") this.metadata[field] = value;
          else this.metadata[field] = value ?? "";
          this.serverMetadata[field] = page.metadata[field];
        }
      }
      await this.persist();
    } while (this.cursor < through);
    this.serverStatus = this.hasPendingChanges()
      ? "未送信の変更あり"
      : "サーバーに保存済み";
  }

  setBody(value: string) {
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
    this.metadata = { ...this.metadata, ...values };
    this.changed();
  }

  private changed() {
    this.revision++;
    this.serverStatus = "未送信の変更あり";
    void this.persist().catch(() => {});
    this.schedule();
    this.emit();
  }

  private schedule() {
    clearTimeout(this.timer);
    this.timer = setTimeout(() => void this.sync(), 1000);
  }

  private persist(): Promise<void> {
    const revision = this.revision;
    const value: SavedDraft = structuredClone({
      state: Y.encodeStateAsUpdate(this.doc),
      metadata: this.metadata,
      serverMetadata: this.serverMetadata,
      pending: this.pending,
      cursor: this.cursor,
      flight: this.flight,
    });
    this.localStatus = "端末に保存中";
    this.writes = this.writes
      .catch(() => {})
      .then(async () => {
        if (!this.database) throw new Error("端末内の保存領域を利用できません");
        await localRecord(this.database, this.id, value);
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
    if (this.isSyncing || this.isClosed) return;
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
        const receipt = await this.request<Receipt>("/updates", "POST", flight);
        if (
          receipt.update_id !== flight.update_id ||
          receipt.digest !== flight.digest
        )
          throw new Error("保存応答が一致しません。本文を保持しています。");
        this.pending = this.pending.filter(
          (item) => !flight.included.includes(item.id),
        );
        this.serverMetadata = receipt.metadata;
        this.flight = undefined;
        await this.persist();
      }
      await this.catchUp();
      this.error = "";
    } catch (error) {
      this.serverStatus = "サーバー保存を確認できません";
      this.error =
        error instanceof Error ? error.message : "保存できませんでした";
    } finally {
      this.isSyncing = false;
      if (!this.error && this.hasPendingChanges()) this.schedule();
      this.emit();
    }
  }

  close() {
    this.isClosed = true;
    clearTimeout(this.timer);
    void this.writes.finally(() => this.database?.close()).catch(() => {});
  }
}
