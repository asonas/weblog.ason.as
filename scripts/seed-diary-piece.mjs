import { createHash, randomUUID } from "node:crypto";
import * as Y from "yjs";
import { reconstructStoredDraft } from "../lambda/draft_worker/storedInput.ts";

let input = "";
for await (const chunk of process.stdin) input += chunk;
const job = JSON.parse(input);
if (job.format !== "legacy") throw new Error("Expected a legacy diary");
const reconstructed = reconstructStoredDraft(job);
const doc = new Y.Doc({ gc: false });
Y.applyUpdate(doc, Buffer.from(reconstructed.data, "base64"));
const vector = Y.encodeStateVector(doc);
const body = doc.getText("body").toString();
const footer = /\n(?:[ \t]*\n)*---\n(?:[ \t]*\n)*((?:\[\[[^\]\r\n]+\]\][ \t]*)+)\s*$/.exec(body);
let tags = [];
let pieceBody = body;
if (footer) {
  let fence;
  for (const line of body.slice(0, footer.index).split("\n")) {
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (!marker) continue;
    if (!fence) fence = marker[1];
    else if (marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = undefined;
  }
  if (!fence) {
    tags = [...new Set([...footer[1].matchAll(/\[\[([^\]]+)\]\]/g)].map(match => match[1].trim()))];
    pieceBody = body.slice(0, footer.index);
  }
}
const pieceId = randomUUID();
doc.transact(() => {
  doc.getText(`piece:${pieceId}`).insert(0, pieceBody);
  doc.getText("body").delete(0, doc.getText("body").length);
});
const data = Buffer.from(Y.encodeStateAsUpdate(doc, vector));
process.stdout.write(JSON.stringify({
  piece_id: pieceId,
  tags,
  data: data.toString("base64"),
  digest: createHash("sha256").update(data).digest("hex"),
  body_digest: createHash("sha256").update(body).digest("hex"),
  body_bytes: Buffer.byteLength(body),
}));
doc.destroy();
