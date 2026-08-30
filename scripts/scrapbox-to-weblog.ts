import { readFile, writeFile } from "node:fs/promises";
import { type Node, type Page, parse } from "@progfay/scrapbox-parser";

type ExportLine = string | { text: string; [key: string]: unknown };

type ScrapboxPage = {
  lines: ExportLine[];
  [key: string]: unknown;
};

type ScrapboxExport = {
  pages: ScrapboxPage[];
  [key: string]: unknown;
};

type JsonObject = Record<string, unknown>;
type ImagePaths = ReadonlyMap<string, string>;
type ConversionMode = "all" | "assets";

const isLinkNode = (node: Node): node is Extract<Node, { type: "link" }> =>
  node.type === "link";

const hasNodes = (node: Node): node is Node & { nodes: Node[] } =>
  "nodes" in node && Array.isArray(node.nodes);

const isJsonObject = (value: unknown): value is JsonObject =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const sourceImageUrl = (url: string): string =>
  url.replace(/\/thumb\/\d+\/?$/, "");

const leadingIndent = (line: string): number =>
  /^\s*/.exec(line)?.[0].length ?? 0;

const specialBlockIndent = (line: string): number | null => {
  const match = /^(\s*)(?:code|table):/.exec(line);
  return match ? match[1].length : null;
};

const renderNode = (
  node: Node,
  imagePaths: ImagePaths,
  mode: ConversionMode,
): string => {
  if (node.type === "image" || node.type === "strongImage") {
    const imagePath = imagePaths.get(sourceImageUrl(node.src));
    return imagePath ? `![](${imagePath})` : node.raw;
  }

  if (node.type === "strong" || node.type === "strongIcon") {
    return node.raw;
  }

  if (isLinkNode(node) && node.pathType === "absolute") {
    const imagePath = imagePaths.get(sourceImageUrl(node.href));
    return imagePath ? `![](${imagePath})` : node.raw;
  }

  if (isLinkNode(node) && node.pathType !== "absolute") {
    return mode === "all" ? `[[${node.href.replace(/^\/+/, "")}]]` : node.raw;
  }

  if (hasNodes(node)) {
    return node.nodes
      .map((child) => renderNode(child, imagePaths, mode))
      .join("");
  }

  return node.raw;
};

const renderLine = (
  line: string,
  imagePaths: ImagePaths,
  mode: ConversionMode,
  renderList: boolean,
): string => {
  const blocks: Page = parse(line, { hasTitle: false });
  return blocks
    .map((block) => {
      if (block.type !== "line") return "text" in block ? block.text : "";

      const text = block.nodes
        .map((node) => renderNode(node, imagePaths, mode))
        .join("");
      if (!renderList || block.indent === 0 || text.trim().length === 0)
        return text;

      return `${"  ".repeat(block.indent - 1)}- ${text}`;
    })
    .join("\n");
};

export const convertLine = (
  line: string,
  imagePaths: ImagePaths = new Map(),
  mode: ConversionMode = "all",
): string => {
  return renderLine(line, imagePaths, mode, true);
};

const convertPageLines = (
  lines: ExportLine[],
  imagePaths: ImagePaths,
  mode: ConversionMode,
): string[] => {
  let specialBlock: number | null = null;

  return lines.map((line) => {
    const text = typeof line === "string" ? line : line.text;
    const indent = leadingIndent(text);
    const isSpecialBlockChild = specialBlock !== null && indent > specialBlock;

    if (!isSpecialBlockChild) specialBlock = specialBlockIndent(text);

    return renderLine(
      text,
      imagePaths,
      mode,
      !isSpecialBlockChild && specialBlock === null,
    );
  });
};

export const convertExport = (
  payload: ScrapboxExport,
  imagePaths: ImagePaths = new Map(),
  mode: ConversionMode = "all",
): ScrapboxExport => ({
  ...payload,
  pages: payload.pages.map((page) => {
    const convertedLines = convertPageLines(page.lines, imagePaths, mode);
    return {
      ...page,
      lines: page.lines.map((line, index) =>
        typeof line === "string"
          ? convertedLines[index]
          : { ...line, text: convertedLines[index] },
      ),
    };
  }),
});

export const buildImagePaths = (
  manifest: unknown,
  report: unknown,
): Map<string, string> => {
  if (!isJsonObject(manifest) || !Array.isArray(manifest.assets)) {
    throw new Error("asset manifest must contain an assets array");
  }
  if (!isJsonObject(report) || !Array.isArray(report.results)) {
    throw new Error("asset fetch report must contain a results array");
  }

  const localPaths = new Map<string, string>();
  for (const result of report.results) {
    if (!isJsonObject(result) || typeof result.id !== "string") continue;
    if (
      result.status === "downloaded" &&
      typeof result.local_path === "string"
    ) {
      localPaths.set(result.id, result.local_path);
    }
  }

  const imagePaths = new Map<string, string>();
  for (const asset of manifest.assets) {
    if (!isJsonObject(asset) || asset.kind !== "image") continue;
    if (typeof asset.id !== "string" || typeof asset.url !== "string") continue;
    const localPath = localPaths.get(asset.id);
    if (localPath) imagePaths.set(asset.url, `/assets/${localPath}`);
  }
  return imagePaths;
};

const option = (argv: string[], name: string): string => {
  const index = argv.indexOf(name);
  const value = argv[index + 1];
  if (index < 0 || value === undefined || value.startsWith("--")) {
    throw new Error(`missing required option: ${name}`);
  }
  return value;
};

const optionalOption = (
  argv: string[],
  name: string,
  fallback: string,
): string => {
  const index = argv.indexOf(name);
  if (index < 0) return fallback;
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("--")) {
    throw new Error(`missing option value: ${name}`);
  }
  return value;
};

const main = async (): Promise<void> => {
  const argv = process.argv.slice(2);
  const inputPath = option(argv, "--input");
  const outputPath = option(argv, "--output");
  const manifestPath = optionalOption(
    argv,
    "--asset-manifest",
    "data/normalized/asset-manifest.json",
  );
  const reportPath = optionalOption(
    argv,
    "--asset-fetch-report",
    "data/reports/asset-fetch-report.json",
  );
  const mode: ConversionMode = argv.includes("--assets-only")
    ? "assets"
    : "all";
  const payload = JSON.parse(
    await readFile(inputPath, "utf8"),
  ) as ScrapboxExport;
  const imagePaths = buildImagePaths(
    JSON.parse(await readFile(manifestPath, "utf8")) as unknown,
    JSON.parse(await readFile(reportPath, "utf8")) as unknown,
  );
  await writeFile(
    outputPath,
    `${JSON.stringify(convertExport(payload, imagePaths, mode), null, 2)}\n`,
    "utf8",
  );
};

if (import.meta.url === `file://${process.argv[1]}`) {
  await main();
}
