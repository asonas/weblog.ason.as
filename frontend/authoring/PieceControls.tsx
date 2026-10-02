import type { DraftSession } from "./draftSession";

export function DraftPieceControls({ session }: { session: DraftSession }) {
  const pieces = session.pieces;
  if (!pieces) return null;
  const diary = session.metadata.page_type === "date";
  if (!diary && !pieces.conflicts.length && !pieces.recovery.length)
    return null;
  return (
    <section className="draft-pieces" aria-label="日記のかけら">
      {pieces.conflicts.length > 0 && (
        <fieldset className="draft-editor__conflict">
          <legend>かけらの並び順・タグが別の画面で変更されています</legend>
          <p>
            この端末:{" "}
            {pieces.local.piece_ids
              .map(
                (id) =>
                  session.doc.getText(`piece:${id}`).toString().slice(0, 40) ||
                  "空のかけら",
              )
              .join(" → ")}{" "}
            / {pieces.local.tags.join("、")}
          </p>
          <p>
            別の編集:{" "}
            {pieces.conflicts[0].piece_ids
              .map(
                (id) =>
                  session.doc.getText(`piece:${id}`).toString().slice(0, 40) ||
                  "空のかけら",
              )
              .join(" → ")}{" "}
            / {pieces.conflicts[0].tags.join("、")}
          </p>
          <button
            type="button"
            onClick={() => session.resolveStructure("local")}
          >
            この端末の並び順・タグを使う
          </button>
          <button
            type="button"
            onClick={() => session.resolveStructure("remote")}
          >
            別の編集を使う
          </button>
        </fieldset>
      )}
      {pieces.recovery.map((id) => (
        <div key={id} className="draft-editor__conflict">
          <p>別の画面で削除されたかけらに、未送信の文章があります。</p>
          <pre>{session.doc.getText(`piece:${id}`).toString()}</pre>
          <button type="button" onClick={() => session.recoverPiece(id)}>
            新しいかけらとして残す
          </button>
        </div>
      ))}
      {diary && (
        <label>
          タグ（カンマ区切り）
          <input
            key={pieces.local.tags.join(",")}
            defaultValue={pieces.local.tags.join(", ")}
            disabled={session.isPublishing}
            onBlur={(event) =>
              session.setTags(event.currentTarget.value.split(/[,、]/))
            }
          />
        </label>
      )}
    </section>
  );
}
