import * as Y from "yjs";
import type { DraftMetadata, SavedDraft } from "./draftSession";

const FIELDS: (keyof DraftMetadata)[] = [
  "title",
  "page_type",
  "cover_mode",
  "cover_image_url",
];

export function mergeLocalDraft(
  base: SavedDraft,
  incoming: SavedDraft,
  stored: SavedDraft,
): SavedDraft {
  const result = structuredClone(stored);
  result.state = Y.mergeUpdates([stored.state, incoming.state]);
  result.cursor = Math.max(stored.cursor, incoming.cursor);
  const oldIds = new Set(base.pending.map(({ id }) => id));
  const currentIds = new Set(incoming.pending.map(({ id }) => id));
  const pending = new Map(
    stored.pending
      .filter(({ id }) => !oldIds.has(id) || currentIds.has(id))
      .map((item) => [item.id, item]),
  );
  for (const item of incoming.pending)
    if (!oldIds.has(item.id)) pending.set(item.id, item);
  result.pending = [...pending.values()];
  if (incoming.flight?.update_id !== base.flight?.update_id)
    result.flight = incoming.flight;
  result.conflicts ||= {};
  result.tabConflicts ||= {};
  for (const field of FIELDS) {
    const local = incoming.metadata[field];
    const remote = stored.metadata[field];
    const previous = base.metadata[field];
    let alternatives = [...(stored.tabConflicts?.[field] || [])];
    const before = base.tabConflicts?.[field] || [];
    const after = incoming.tabConflicts?.[field] || [];
    alternatives = alternatives.filter(
      (value) => !before.includes(value) || after.includes(value),
    );
    alternatives.push(...after.filter((value) => !before.includes(value)));
    if (local !== previous) {
      if (remote !== previous && remote !== local) alternatives.push(remote);
      if (field === "cover_image_url") result.metadata[field] = local;
      else result.metadata[field] = local ?? "";
    }
    alternatives = [...new Set(alternatives)].filter(
      (value) => value !== result.metadata[field],
    );
    if (alternatives.length) result.tabConflicts[field] = alternatives;
    else delete result.tabConflicts[field];
    if (
      incoming.serverMetadata[field].revision >
      stored.serverMetadata[field].revision
    )
      result.serverMetadata[field] = incoming.serverMetadata[field];
    if (
      JSON.stringify(incoming.conflicts?.[field]) !==
      JSON.stringify(base.conflicts?.[field])
    ) {
      if (incoming.conflicts?.[field])
        result.conflicts[field] = incoming.conflicts[field];
      else delete result.conflicts[field];
    }
  }
  return result;
}
