import assert from "node:assert/strict";
import test from "node:test";

import { EncryptedJson } from "./crypto.js";

test("encrypted OAuth data round-trips without exposing plaintext", () => {
  const codec = new EncryptedJson(Buffer.alloc(32, 7));
  const value = { access_token: "secret-token", expires_at: 1234 };
  const encrypted = codec.encrypt(value);

  assert.doesNotMatch(encrypted, /secret-token/);
  assert.deepEqual(codec.decrypt(encrypted), value);
});

test("encrypted OAuth data rejects tampering", () => {
  const codec = new EncryptedJson(Buffer.alloc(32, 7));
  const encrypted = codec.encrypt({ state: "pending" });
  const envelope = JSON.parse(encrypted) as { ciphertext: string };
  envelope.ciphertext = `${envelope.ciphertext.slice(0, -2)}AA`;

  assert.throws(() => codec.decrypt(JSON.stringify(envelope)));
});
