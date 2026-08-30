import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

type Envelope = { version: 1; iv: string; tag: string; ciphertext: string };

export class EncryptedJson {
  constructor(private readonly key: Buffer) {
    if (key.length !== 32)
      throw new TypeError("OAuth encryption key must be 32 bytes");
  }

  encrypt(value: unknown): string {
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", this.key, iv);
    const ciphertext = Buffer.concat([
      cipher.update(JSON.stringify(value), "utf8"),
      cipher.final(),
    ]);
    const envelope: Envelope = {
      version: 1,
      iv: iv.toString("base64url"),
      tag: cipher.getAuthTag().toString("base64url"),
      ciphertext: ciphertext.toString("base64url"),
    };
    return JSON.stringify(envelope);
  }

  decrypt<T>(serialized: string): T {
    const envelope = JSON.parse(serialized) as Envelope;
    if (envelope.version !== 1)
      throw new TypeError("Unsupported OAuth ciphertext version");
    const decipher = createDecipheriv(
      "aes-256-gcm",
      this.key,
      Buffer.from(envelope.iv, "base64url"),
    );
    decipher.setAuthTag(Buffer.from(envelope.tag, "base64url"));
    return JSON.parse(
      Buffer.concat([
        decipher.update(Buffer.from(envelope.ciphertext, "base64url")),
        decipher.final(),
      ]).toString("utf8"),
    ) as T;
  }
}
