import { spawnSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const [homeUrl, articleUrl, outputDirectory] = process.argv.slice(2);
if (!homeUrl || !articleUrl || !outputDirectory) {
  throw new Error("Usage: node scripts/benchmark-public-pages.mjs HOME_URL ARTICLE_URL OUTPUT_DIRECTORY");
}
const directory = resolve(outputDirectory);
mkdirSync(directory, { recursive: true });
const measurements = [];
for (const [page, url] of [["home", homeUrl], ["article", articleUrl]]) {
  for (const device of ["mobile", "desktop"]) {
    for (let run = 1; run <= 3; run++) {
      const output = `${directory}/${page}-${device}-${run}`;
      const args = ["--yes", "lighthouse@13.4.0", url, "--chrome-flags=--headless",
        "--output=json", "--output=html", `--output-path=${output}`, "--quiet"];
      if (device === "desktop") args.push("--preset=desktop");
      const processResult = spawnSync("npx", args, { stdio: "inherit" });
      if (processResult.status !== 0) throw new Error(`Lighthouse failed: ${page} ${device} ${run}`);
      const result = JSON.parse(readFileSync(`${output}.report.json`, "utf8"));
      if (result.runtimeError) throw new Error(result.runtimeError.message);
      const measurement = {
        page, device, run, url: result.finalDisplayedUrl, lighthouse: result.lighthouseVersion,
        userAgent: result.environment.hostUserAgent,
        score: Math.round(result.categories.performance.score * 100),
        lcp: result.audits["largest-contentful-paint"].numericValue,
        cls: result.audits["cumulative-layout-shift"].numericValue,
        bytes: result.audits["total-byte-weight"].numericValue,
      };
      measurements.push(measurement);
      writeFileSync(`${directory}/measurements.json`, JSON.stringify(measurements, null, 2));
      console.log(JSON.stringify(measurement));
    }
  }
}
