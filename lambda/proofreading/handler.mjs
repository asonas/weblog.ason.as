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
  return {
    messages: result.messages.map(({ ruleId, message, line, range }) => ({
      ruleId, message, line, range,
    })),
  };
}
