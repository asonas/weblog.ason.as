import { createHash, randomUUID } from "node:crypto";
import * as Y from "yjs";

export function migrateArticle(
  data: string | Uint8Array,
  through: number,
  diary: boolean,
) {
  const doc = new Y.Doc({ gc: false });
  try {
    Y.applyUpdate(
      doc,
      typeof data === "string" ? Buffer.from(data, "base64") : data,
    );
    const vector = Y.encodeStateVector(doc);
    const original = doc.getText("body").toString();
    const body = original.replaceAll("\r\n", "\n");
    let fence: { character: string; length: number } | undefined;
    const bodies: string[] = [];
    let lines: string[] = [];
    const flush = () => {
      const text = lines.join("\n");
      if (text.trim()) bodies.push(text);
      lines = [];
    };
    for (const line of body.split("\n")) {
      const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
      if (marker) {
        const token = marker[1];
        if (!fence) fence = { character: token[0], length: token.length };
        else if (
          token[0] === fence.character &&
          token.length >= fence.length &&
          !marker[2].trim()
        )
          fence = undefined;
      }
      if (!fence && !marker && line === "---") flush();
      else lines.push(line);
    }
    flush();
    let tags: string[] = [];
    const last = bodies.at(-1);
    if (
      diary &&
      bodies.length > 1 &&
      last &&
      /^(?:\s*\[\[[^\]\r\n]+\]\]\s*)+$/.test(last)
    ) {
      tags = [
        ...new Set(
          [...last.matchAll(/\[\[([^\]]+)\]\]/g)].map((match) =>
            match[1].trim(),
          ),
        ),
      ];
      bodies.pop();
    }
    if (!bodies.length) bodies.push("");
    const ids = bodies.map(() => randomUUID());
    doc.transact(() => {
      bodies.forEach((text, index) => {
        doc.getText(`piece:${ids[index]}`).insert(0, text);
      });
      doc.getText("body").delete(0, original.length);
    });
    const update = Buffer.from(Y.encodeStateAsUpdate(doc, vector));
    return {
      source_head: through,
      piece_id: ids[0],
      piece_ids: ids,
      tags,
      data: update.toString("base64"),
      digest: createHash("sha256").update(update).digest("hex"),
      body_bytes: Buffer.byteLength(original),
    };
  } finally {
    doc.destroy();
  }
}
