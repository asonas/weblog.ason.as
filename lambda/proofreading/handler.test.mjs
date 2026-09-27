import assert from "node:assert/strict";
import { test } from "node:test";
import { handler } from "./handler.mjs";

test("reports technical writing issues with positions in the original Markdown", async () => {
  const text = "# 試し書き\n\n見れる。\n\n値を返却する。\n\n三回実行します。\n\nｶﾀｶﾅです。";
  const { messages } = await handler({ text });
  for (const rule of ["no-dropping-the-ra", "ja-no-abusage", "arabic-kanji-numbers", "no-hankaku-kana"]) {
    assert.ok(messages.some(({ ruleId }) => ruleId === rule), rule);
  }
  const ra = messages.find(({ ruleId }) => ruleId === "no-dropping-the-ra");
  assert.equal(ra.line, 3);
  assert.equal(text.slice(...ra.range), "れ");
});

test("allows the five explicitly excluded writing styles", async () => {
  const samples = [
    "あ".repeat(101) + "。",
    "a,b,c,d,e.",
    "春、夏、秋、冬、季節を楽しむ。",
    "これは本です。これは本である。",
    "本当? 本当？ すごい! すごい！",
  ];
  const disabled = ["sentence-length", "max-comma", "max-ten", "no-mix-dearu-desumasu", "no-exclamation-question-mark"];
  for (const text of samples) {
    const { messages } = await handler({ text });
    assert.deepEqual(messages.filter(({ ruleId }) => disabled.includes(ruleId)), []);
  }
});

test("rejects invalid or oversized text before linting", async () => {
  for (const text of [null, 42, "あ".repeat(333334)]) {
    await assert.rejects(handler({ text }), /1 MB/);
  }
});
