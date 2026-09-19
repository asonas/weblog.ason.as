import { createHash } from "node:crypto";
import * as Y from "yjs";
import { reconstructDraft } from "../../../lambda/draft_worker/reconstruct.ts";

if (process.argv[2] === "history") {
  const doc = new Y.Doc();
  const updates = [];
  doc.on("update", (data) => updates.push({ data: Buffer.from(data).toString("base64"), digest: createHash("sha256").update(data).digest("hex") }));
  doc.getText("body").insert(0, "残す消す");
  doc.getText("body").delete(2, 2);
  process.stdout.write(JSON.stringify(updates));
  doc.destroy();
} else {
  let json = "";
  for await (const chunk of process.stdin) json += chunk;
  const input = JSON.parse(json);
  const decode = (payload) => ({ ...payload, data: Buffer.from(payload.data, "base64") });
  const result = reconstructDraft({ ...input, checkpoint: input.checkpoint ? decode(input.checkpoint) : undefined, updates: input.updates.map(decode) });
  process.stdout.write(JSON.stringify({ ...result, article_id: input.article_id, data: Buffer.from(result.data).toString("base64") }));
}
