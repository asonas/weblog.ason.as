import { createHash } from "node:crypto";
import * as Y from "yjs";
import { reconstructStoredDraft } from "../../../lambda/draft_worker/storedInput.ts";

if (process.argv[2] === "history") {
  const doc = new Y.Doc();
  const updates = [];
  doc.on("update", (data) => updates.push({ data: Buffer.from(data).toString("base64"), digest: createHash("sha256").update(data).digest("hex") }));
  if (process.argv[3] === "large") {
    for (let index = 0; index < 3; index++) {
      doc.getText("body").insert(0, "x".repeat(400 * 1024));
      doc.getText("body").delete(0, 400 * 1024);
    }
  } else {
    doc.getText("body").insert(0, "残す消す");
    doc.getText("body").delete(2, 2);
  }
  process.stdout.write(JSON.stringify(updates));
  doc.destroy();
} else {
  let json = "";
  for await (const chunk of process.stdin) json += chunk;
  const input = JSON.parse(json);
  process.stdout.write(JSON.stringify(reconstructStoredDraft(input)));
}
