import { TextlintKernel } from "@textlint/kernel";
import { moduleInterop } from "@textlint/module-interop";
import markdownPlugin from "@textlint/textlint-plugin-markdown";
import technicalWritingPreset from "textlint-rule-preset-ja-technical-writing";

const preset = moduleInterop(technicalWritingPreset);
const disabledRules = new Set([
  "sentence-length",
  "max-comma",
  "max-ten",
  "no-mix-dearu-desumasu",
  "no-exclamation-question-mark",
]);
const kernel = new TextlintKernel();
const options = {
  ext: ".md",
  filePath: "draft.md",
  plugins: [{ pluginId: "markdown", plugin: moduleInterop(markdownPlugin) }],
  rules: Object.entries(preset.rules)
    .filter(([ruleId]) => !disabledRules.has(ruleId))
    .map(([ruleId, rule]) => ({ ruleId, rule, options: preset.rulesConfig[ruleId] })),
};

export async function handler(event) {
  if (typeof event?.text !== "string" || Buffer.byteLength(event.text, "utf8") > 1_000_000) {
    throw new Error("校正する本文は UTF-8 で 1 MB 以下の文字列にしてください");
  }
  const result = await kernel.lintText(event.text, options);
  let trailingTagsStart = event.text.length;
  const lines = event.text.split("\n");
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    const line = lines[index].trim();
    if (line && !/^(?:\[\[[^\[\]\r\n]+\]\]\s*)+$/u.test(line)) break;
    trailingTagsStart -= lines[index].length + (index < lines.length - 1 ? 1 : 0);
  }
  return {
    messages: result.messages.filter(({ ruleId, range }) => !(
      ruleId === "ja-no-mixed-period" && range[0] >= trailingTagsStart
    )).map(({ ruleId, message, line, range }) => ({
      ruleId, message, line, range,
    })),
  };
}
