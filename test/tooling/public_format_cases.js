import fs from "node:fs";

const source = fs.readFileSync(process.argv[2], "utf8");
const load = (enabled) => new Function(`${source.replace("var markdownEnabled = false;", `var markdownEnabled = ${enabled};`)}; return handler;`)();
const format = (handler, uri, accept) => {
  const headers = { "x-weblog-format": { value: "markdown" } };
  if (accept) headers.accept = accept;
  return handler({ request: { uri, headers } }).headers["x-weblog-format"].value;
};

const enabled = load(true);
const disabled = load(false);
const results = {
  missing: format(enabled, "/article", undefined),
  browser: format(enabled, "/article", { value: "text/html,application/xhtml+xml,*/*;q=0.8" }),
  markdown: format(enabled, "/article", { value: "text/markdown" }),
  weighted: format(enabled, "/article", { value: "text/html, TEXT/Markdown;q=0.9" }),
  refused: format(enabled, "/article", { value: "text/html, text/markdown;q=0" }),
  lookalike: format(enabled, "/article", { value: "text/markdownx, text/html;profile=text/markdown" }),
  multiValue: format(enabled, "/article", { value: "text/html", multiValue: [{ value: "text/html" }, { value: "text/markdown" }] }),
  feed: format(enabled, "/feed.xml", { value: "text/markdown" }),
  sitemap: format(enabled, "/sitemap.xml/", { value: "text/markdown" }),
  disabled: format(disabled, "/article", { value: "text/markdown" }),
};
process.stdout.write(JSON.stringify(results));
