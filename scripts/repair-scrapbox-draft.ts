import { createHash } from "node:crypto";
import * as Y from "yjs";
import { reconstructStoredDraft } from "../lambda/draft_worker/storedInput.ts";

export const repairDraft = (job: unknown, before: string, after: string) => {
  const restored = reconstructStoredDraft(job);
  if (restored.markdown !== before)
    throw new Error("Working draft differs from the approved published body");
  const originalLines = before.split("\n");
  const changedLines = after.split("\n");
  if (originalLines.length !== changedLines.length)
    throw new Error("Hashtag repair must preserve line boundaries");
  const doc = new Y.Doc({ gc: false });
  const verification = new Y.Doc({ gc: false });
  try {
    const original = Buffer.from(restored.data, "base64");
    Y.applyUpdate(doc, original);
    const vector = Y.encodeStateVector(doc);
    const text = doc.getText("body");
    let offset = before.length;
    for (let index = originalLines.length - 1; index >= 0; index--) {
      const oldLine = originalLines[index];
      const newLine = changedLines[index];
      offset -= oldLine.length;
      if (oldLine !== newLine) {
        let start = 0;
        while (start < oldLine.length && oldLine[start] === newLine[start])
          start++;
        let end = 0;
        while (
          end < oldLine.length - start &&
          end < newLine.length - start &&
          oldLine[oldLine.length - end - 1] ===
            newLine[newLine.length - end - 1]
        )
          end++;
        text.delete(offset + start, oldLine.length - start - end);
        text.insert(offset + start, newLine.slice(start, newLine.length - end));
      }
      offset--;
    }
    const data = Buffer.from(Y.encodeStateAsUpdate(doc, vector));
    Y.applyUpdate(verification, original);
    Y.applyUpdate(verification, data);
    if (verification.getText("body").toString() !== after)
      throw new Error("Hashtag repair failed reconstruction verification");
    return {
      data: data.toString("base64"),
      digest: createHash("sha256").update(data).digest("hex"),
      body_bytes: Buffer.byteLength(after),
    };
  } finally {
    doc.destroy();
    verification.destroy();
  }
};

if (import.meta.url === `file://${process.argv[1]}`) {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  const { job, before, after } = JSON.parse(input);
  process.stdout.write(JSON.stringify(repairDraft(job, before, after)));
}
