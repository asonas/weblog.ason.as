import { type Editor, Extension } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";

const key = new PluginKey<DecorationSet>("videoUploadCards");

export const VideoUploadCards = Extension.create({
  name: "videoUploadCards",
  addProseMirrorPlugins() {
    return [
      new Plugin<DecorationSet>({
        key,
        state: {
          init: () => DecorationSet.empty,
          apply(tr, previous) {
            let decorations = previous.map(tr.mapping, tr.doc, {
              onRemove: (spec) => spec.cancel(),
            });
            const action = tr.getMeta(key);
            if (action?.add)
              decorations = decorations.add(tr.doc, [action.add]);
            if (action?.remove)
              decorations = decorations.remove(
                decorations.find().filter((d) => d.spec.id === action.remove),
              );
            return decorations;
          },
        },
        props: { decorations: (state) => key.getState(state) },
      }),
    ];
  },
});

export function createVideoUploadCard(
  editor: Editor,
  file: File,
  parentSignal: AbortSignal,
) {
  const id = {};
  const controller = new AbortController();
  const card = document.createElement("span");
  card.className = "video-upload-card";
  card.contentEditable = "false";
  const icon = document.createElement("span");
  icon.className = "video-upload-card__icon";
  icon.setAttribute("aria-hidden", "true");
  icon.innerHTML =
    '<svg viewBox="0 0 32 32" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="3" y="6" width="26" height="20" rx="2"/><path d="m13 11 8 5-8 5z"/></svg>';
  const info = document.createElement("span");
  info.className = "video-upload-card__info";
  const name = document.createElement("strong");
  name.textContent = file.name;
  const status = document.createElement("span");
  status.className = "video-upload-card__status";
  status.setAttribute("role", "status");
  const progress = document.createElement("progress");
  progress.max = 100;
  progress.setAttribute("aria-label", "動画の変換進捗");
  const actions = document.createElement("span");
  actions.className = "video-upload-card__actions";
  const retry = document.createElement("button");
  retry.type = "button";
  retry.textContent = "再試行";
  retry.hidden = true;
  const cancel = document.createElement("button");
  cancel.type = "button";
  cancel.textContent = "キャンセル";
  info.append(name, status, progress);
  actions.append(retry, cancel);
  card.append(icon, info, actions);
  const find = () =>
    key
      .getState(editor.state)
      ?.find()
      .find((d) => d.spec.id === id);
  const remove = () => {
    if (!editor.isDestroyed)
      editor.view.dispatch(editor.state.tr.setMeta(key, { remove: id }));
  };
  const abort = () => {
    controller.abort();
    remove();
  };
  cancel.onclick = abort;
  parentSignal.addEventListener("abort", abort, { once: true });
  editor.on("destroy", abort);
  editor.view.dispatch(
    editor.state.tr.setMeta(key, {
      add: Decoration.widget(editor.state.selection.from, card, {
        id,
        side: 1,
        cancel: () => controller.abort(),
        stopEvent: () => true,
      }),
    }),
  );
  const update = (message: string) => {
    if (controller.signal.aborted) return;
    card.classList.remove("video-upload-card--error");
    status.textContent = message;
    retry.hidden = true;
    progress.hidden = false;
    const percent = /(\d+)%/.exec(message);
    if (percent) progress.value = Number(percent[1]);
    else progress.removeAttribute("value");
    cancel.textContent = "キャンセル";
  };
  update("順番を待っています…");
  return {
    signal: controller.signal,
    update,
    async retry(error: unknown): Promise<boolean> {
      if (controller.signal.aborted) return false;
      card.classList.add("video-upload-card--error");
      status.textContent =
        error instanceof Error ? error.message : "動画を追加できませんでした";
      progress.hidden = true;
      retry.hidden = false;
      cancel.textContent = "取り消す";
      return new Promise((resolve) => {
        const aborted = () => {
          retry.onclick = null;
          resolve(false);
        };
        controller.signal.addEventListener("abort", aborted, { once: true });
        retry.onclick = () => {
          if (!editor.isEditable) return;
          controller.signal.removeEventListener("abort", aborted);
          retry.onclick = null;
          resolve(true);
        };
      });
    },
    complete(attrs: {
      avc: string;
      av1?: string;
      width: number;
      height: number;
    }) {
      if (controller.signal.aborted || editor.isDestroyed || !editor.isEditable)
        return;
      const anchor = find();
      if (!anchor) return;
      editor
        .chain()
        .insertContentAt(
          anchor.from,
          { type: "video", attrs },
          { updateSelection: false },
        )
        .command(({ tr }) => {
          tr.setMeta(key, { remove: id });
          return true;
        })
        .run();
    },
    dispose() {
      parentSignal.removeEventListener("abort", abort);
      editor.off("destroy", abort);
      remove();
    },
  };
}
