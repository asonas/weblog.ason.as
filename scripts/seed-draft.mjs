import { createHash } from "node:crypto";
import * as Y from "yjs";

let input = "";
for await (const chunk of process.stdin) input += chunk;
const body = JSON.parse(input);
if (typeof body !== "string" || Buffer.byteLength(body, "utf8") > 512 * 1024)
  throw new Error("Invalid migration body");
const doc = new Y.Doc();
doc.getText("body").insert(0, body);
const data = Buffer.from(Y.encodeStateAsUpdate(doc));
const verified = new Y.Doc();
Y.applyUpdate(verified, data);
if (verified.getText("body").toString() !== body)
  throw new Error("Migration body did not round-trip");
process.stdout.write(JSON.stringify({
  data: data.toString("base64"),
  digest: createHash("sha256").update(data).digest("hex"),
}));
verified.destroy();
doc.destroy();
