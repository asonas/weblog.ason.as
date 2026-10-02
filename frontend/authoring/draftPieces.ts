import type * as Y from "yjs";

export function parsePieceTags(value: string): string[] {
  return [
    ...new Set(
      Array.from(value.matchAll(/\[\[([^[\]\n]+)\]\]|([^[\],、]+)/g), (match) =>
        (match[1] ?? match[2]).trim(),
      ).filter(Boolean),
    ),
  ];
}

export type PieceStructure = {
  revision: number;
  piece_ids: string[];
  deleted_ids: string[];
  tags: string[];
};

export type DraftPieces = {
  local: PieceStructure;
  server: PieceStructure;
  conflicts: PieceStructure[];
  recovery: string[];
};

export function sameStructure(a: PieceStructure, b: PieceStructure): boolean {
  return (
    JSON.stringify([a.piece_ids, [...a.deleted_ids].sort(), a.tags]) ===
    JSON.stringify([b.piece_ids, [...b.deleted_ids].sort(), b.tags])
  );
}

export function pieceContent(doc: Y.Doc, structure: PieceStructure) {
  return {
    format: "pieces" as const,
    pieces: structure.piece_ids.map((id) => ({
      id,
      body: doc.getText(`piece:${id}`).toString(),
    })),
    tags: structure.tags,
  };
}

export function pieceMarkdown(doc: Y.Doc, structure: PieceStructure): string {
  const content = pieceContent(doc, structure);
  const body = content.pieces.map((piece) => piece.body).join("\n\n---\n\n");
  return [body, content.tags.map((tag) => `[[${tag}]]`).join(" ")]
    .filter(Boolean)
    .join("\n\n");
}

export function receiveStructure(
  state: DraftPieces,
  remote: PieceStructure,
): DraftPieces {
  if (remote.revision < state.server.revision) return state;
  const result = structuredClone(state);
  if (
    sameStructure(state.local, state.server) ||
    sameStructure(state.local, remote)
  ) {
    result.local = remote;
  } else if (remote.revision > state.server.revision) {
    result.conflicts = [...state.conflicts, remote];
  }
  result.server = remote;
  return result;
}

export function mergePieceDrafts(
  base: DraftPieces | undefined,
  incoming: DraftPieces | undefined,
  stored: DraftPieces | undefined,
): DraftPieces | undefined {
  if (!incoming) return stored;
  if (!stored || !base) return structuredClone(incoming);
  const result = receiveStructure(stored, incoming.server);
  if (!sameStructure(incoming.local, base.local)) {
    if (
      !sameStructure(stored.local, base.local) &&
      !sameStructure(stored.local, incoming.local)
    )
      result.conflicts.push(stored.local);
    result.local = incoming.local;
  }
  const retained = result.conflicts.filter(
    (conflict) =>
      !base.conflicts.some((old) => sameStructure(old, conflict)) ||
      incoming.conflicts.some((other) => sameStructure(other, conflict)),
  );
  result.conflicts = [...retained, ...incoming.conflicts].filter(
    (conflict, index, all) =>
      !sameStructure(conflict, result.local) &&
      all.findIndex((other) => sameStructure(other, conflict)) === index,
  );
  result.recovery = [
    ...new Set([
      ...stored.recovery.filter(
        (id) => !base.recovery.includes(id) || incoming.recovery.includes(id),
      ),
      ...incoming.recovery,
    ]),
  ];
  return result;
}
