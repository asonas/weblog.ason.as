import type { DraftSession } from "./draftSession";

type MemoFlight = {
  kind: "save" | "delete" | "adopt";
  path: string;
  method: "PUT" | "DELETE" | "POST";
  payload: {
    operation_id: string;
    expected_revision: number;
    body?: string;
    memo_id?: string;
    piece_id?: string;
    structure_revision?: number;
  };
};
export type LocalMemo = {
  key: string;
  id: string;
  body: string;
  savedBody: string;
  revision: number;
  updatedAt: string;
  flight?: MemoFlight;
  error?: string;
};
type ServerMemo = {
  id: string;
  body: string;
  revision: number;
  updated_at: string;
};
type MemoReceipt = {
  id: string;
  revision: number;
  state: string;
  result: string;
};
class MemoRequestError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

export function memoNeedsSave(memo: LocalMemo) {
  return memo.revision === 0 || memo.body !== memo.savedBody;
}

export function acceptMemoSave(
  memo: LocalMemo,
  flight: MemoFlight,
  receipt: MemoReceipt,
): LocalMemo {
  return {
    ...memo,
    id: receipt.id,
    revision: receipt.revision,
    savedBody: flight.payload.body ?? memo.savedBody,
    flight: undefined,
    error:
      receipt.result === "preserved_as_new"
        ? "別の編集があったため、新しいメモとして保存しました"
        : undefined,
  };
}

export class MemoStore extends EventTarget {
  error = "";
  private constructor(private readonly db: IDBDatabase) {
    super();
  }
  private channel = new BroadcastChannel("weblog-inbox-memos");
  private timer?: ReturnType<typeof setTimeout>;
  private isClosed = false;
  private readonly refresh = () => {
    void this.sync().catch(() => {});
  };
  private readonly changed = () => this.dispatchEvent(new Event("change"));

  static async open() {
    const db = await new Promise<IDBDatabase>((resolve, reject) => {
      const request = indexedDB.open("weblog-inbox-memos-v1", 1);
      request.onupgradeneeded = () =>
        request.result.createObjectStore("memos", { keyPath: "key" });
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      request.onblocked = () =>
        reject(
          new Error(
            "メモの保存領域を開けません。他の画面を閉じて再試行してください。",
          ),
        );
    });
    const store = new MemoStore(db);
    store.channel.onmessage = store.changed;
    window.addEventListener("online", store.refresh);
    window.addEventListener("focus", store.refresh);
    return store;
  }

  async list(): Promise<LocalMemo[]> {
    return new Promise((resolve, reject) => {
      const request = this.db
        .transaction("memos")
        .objectStore("memos")
        .getAll();
      request.onsuccess = () =>
        resolve(
          (request.result as LocalMemo[]).sort((a, b) =>
            b.updatedAt.localeCompare(a.updatedAt),
          ),
        );
      request.onerror = () => reject(request.error);
    });
  }

  private async change(
    key: string,
    update: (memo: LocalMemo | undefined) => LocalMemo | undefined,
  ) {
    await new Promise<void>((resolve, reject) => {
      const transaction = this.db.transaction("memos", "readwrite");
      const table = transaction.objectStore("memos");
      const request = table.get(key);
      let failure: unknown;
      request.onsuccess = () => {
        try {
          const value = update(request.result);
          if (value) table.put(value);
          else table.delete(key);
        } catch (error) {
          failure = error;
          transaction.abort();
        }
      };
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => reject(transaction.error);
      transaction.onabort = () => reject(failure || transaction.error);
    });
    this.channel.postMessage(null);
    this.changed();
  }

  async add(body = "") {
    const id = crypto.randomUUID();
    await this.change(id, () => ({
      key: id,
      id,
      body,
      savedBody: "",
      revision: 0,
      updatedAt: new Date().toISOString(),
    }));
    this.schedule();
    return id;
  }

  async edit(key: string, body: string, previousBody: string) {
    let preserveAsNew = false;
    await this.change(key, (memo) => {
      if (
        !memo ||
        memo.body !== previousBody ||
        memo.flight?.kind === "adopt" ||
        memo.flight?.kind === "delete"
      ) {
        preserveAsNew = true;
        return memo;
      }
      return {
        ...memo,
        body,
        updatedAt: new Date().toISOString(),
        error: undefined,
      };
    });
    if (preserveAsNew) return this.add(body);
    this.schedule();
    return key;
  }

  private schedule() {
    clearTimeout(this.timer);
    this.timer = setTimeout(this.refresh, 800);
  }

  private async request<T>(
    path: string,
    method = "GET",
    payload?: MemoFlight["payload"],
  ): Promise<T> {
    const response = await fetch(path, {
      method,
      credentials: "same-origin",
      cache: "no-store",
      signal: AbortSignal.timeout(15000),
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": document.documentElement.dataset.csrfToken || "",
      },
      body: payload ? JSON.stringify(payload) : undefined,
    });
    const result = await response.json();
    if (!response.ok)
      throw new MemoRequestError(
        result.error || `メモを保存できませんでした (${response.status})`,
        response.status,
      );
    return result;
  }

  async sync() {
    if (this.isClosed) return;
    await navigator.locks
      .request("inbox-memo-sync", async () => {
        if (this.isClosed) return;
        for (const memo of await this.list()) {
          if (!memo.flight && !memoNeedsSave(memo)) continue;
          let flight = memo.flight;
          if (!flight) {
            if (new TextEncoder().encode(memo.body).length > 512 * 1024) {
              await this.change(
                memo.key,
                (current) =>
                  current && {
                    ...current,
                    error:
                      "本文が512 KiBを超えています。端末には保存されています。",
                  },
              );
              continue;
            }
            flight = {
              kind: "save",
              path: `/api/inbox/memos/${memo.id}`,
              method: "PUT",
              payload: {
                operation_id: crypto.randomUUID(),
                expected_revision: memo.revision,
                body: memo.body,
              },
            };
            const pending = flight;
            await this.change(
              memo.key,
              (current) => current && { ...current, flight: pending },
            );
          }
          try {
            const receipt = await this.request<MemoReceipt>(
              flight.path,
              flight.method,
              flight.payload,
            );
            const sent = flight;
            await this.change(
              memo.key,
              (current) =>
                current &&
                (sent.kind === "save"
                  ? acceptMemoSave(current, sent, receipt)
                  : undefined),
            );
          } catch (error) {
            await this.change(
              memo.key,
              (current) =>
                current && {
                  ...current,
                  flight:
                    error instanceof MemoRequestError &&
                    error.status === 409 &&
                    current.flight?.kind !== "save"
                      ? undefined
                      : current.flight,
                  error:
                    error instanceof Error
                      ? error.message
                      : "通信を確認できません。端末に文章を保持しています。",
                },
            );
            throw error;
          }
        }
        const result = await this.request<{ memos: ServerMemo[] }>(
          "/api/inbox/memos",
        );
        const local = await this.list();
        for (const remote of result.memos) {
          const key =
            local.find((memo) => memo.id === remote.id)?.key || remote.id;
          await this.change(key, (current) =>
            current && (current.flight || memoNeedsSave(current))
              ? current
              : {
                  key,
                  id: remote.id,
                  body: remote.body,
                  savedBody: remote.body,
                  revision: remote.revision,
                  updatedAt: remote.updated_at,
                  error: current?.error,
                },
          );
        }
        for (const memo of local) {
          if (!result.memos.some((remote) => remote.id === memo.id))
            await this.change(memo.key, (current) =>
              current && (current.flight || memoNeedsSave(current))
                ? current
                : undefined,
            );
        }
      })
      .catch((error: unknown) => {
        this.error =
          error instanceof Error
            ? error.message
            : "通信を確認できません。端末に文章を保持しています。";
        if (
          !this.isClosed &&
          (!(error instanceof MemoRequestError) ||
            error.status >= 500 ||
            [408, 429].includes(error.status))
        ) {
          clearTimeout(this.timer);
          this.timer = setTimeout(this.refresh, 5000);
        }
        this.changed();
        throw error;
      });
    this.error = "";
    this.changed();
    if ((await this.list()).some((memo) => memo.flight || memoNeedsSave(memo)))
      this.schedule();
  }

  async remove(key: string) {
    await this.sync();
    await navigator.locks.request("inbox-memo-sync", async () => {
      await this.change(key, (memo) => {
        if (!memo) return memo;
        if (memoNeedsSave(memo) || memo.flight)
          throw new Error("メモの変更を保存してから削除してください。");
        return {
          ...memo,
          flight: {
            kind: "delete",
            path: `/api/inbox/memos/${memo.id}`,
            method: "DELETE",
            payload: {
              operation_id: crypto.randomUUID(),
              expected_revision: memo.revision,
            },
          },
        };
      });
    });
    await this.sync();
  }

  async adopt(key: string, session: DraftSession) {
    await this.sync();
    await navigator.locks.request("inbox-memo-sync", async () => {
      const memo = (await this.list()).find((item) => item.key === key);
      if (!memo || memoNeedsSave(memo) || memo.flight)
        throw new Error("メモの保存を確認してから取り込んでください。");
      const payload = await session.prepareMemoAdoption(memo.id, memo.revision);
      await this.change(key, (current) => {
        if (
          !current ||
          current.body !== memo.body ||
          current.revision !== memo.revision ||
          current.flight
        )
          throw new Error(
            "メモが更新されました。内容を確認して取り込み直してください。",
          );
        return {
          ...current,
          flight: {
            kind: "adopt",
            path: `/api/authoring/drafts/${session.id}/memos`,
            method: "POST",
            payload,
          },
        };
      });
    });
    await this.sync();
    await session.sync();
  }

  close() {
    this.isClosed = true;
    clearTimeout(this.timer);
    window.removeEventListener("online", this.refresh);
    window.removeEventListener("focus", this.refresh);
    this.channel.close();
    this.db.close();
  }
}
