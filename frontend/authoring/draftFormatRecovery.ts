import * as Y from "yjs";
import type { SavedDraft } from "./draftSession";

export function recoverLegacyFormat(saved: SavedDraft): SavedDraft {
  const legacyPending = saved.pending.filter((update) => !update.piece_id);
  const legacyFlight = saved.flight && saved.flight.format !== "pieces";
  if (!legacyPending.length && !legacyFlight) return saved;
  const doc = new Y.Doc();
  try {
    Y.applyUpdate(doc, saved.state);
    return {
      ...saved,
      legacyRecovery: saved.legacyRecovery || {
        body: doc.getText("body").toString(),
        metadata: structuredClone(saved.metadata),
        state: saved.state,
      },
      pending: saved.pending.filter((update) => update.piece_id),
      flight: legacyFlight ? undefined : saved.flight,
    };
  } finally {
    doc.destroy();
  }
}
