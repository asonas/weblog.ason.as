import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const chromePath =
  process.env.CHROME_PATH ||
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const baseUrl = process.argv[2] || "http://127.0.0.1:5174/editor/new";
const runs = Number.parseInt(process.argv[3] || "30", 10);
const debuggingPort = 9_238;
const profilePath = await mkdtemp(join(tmpdir(), "weblog-telemetry-benchmark-"));
const chrome = spawn(chromePath, [
  "--headless=new",
  `--remote-debugging-port=${debuggingPort}`,
  `--user-data-dir=${profilePath}`,
  "--disable-background-networking",
  "--disable-default-apps",
  "--disable-extensions",
  "--no-first-run",
  "about:blank",
]);

const delay = (milliseconds) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

async function debuggingEndpoint(path) {
  const response = await fetch(`http://127.0.0.1:${debuggingPort}${path}`, {
    method: path.startsWith("/json/new") ? "PUT" : "GET",
  });
  if (!response.ok) throw new Error(`Chrome DevTools returned ${response.status}`);
  return response.json();
}

async function waitForChrome() {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      return await debuggingEndpoint("/json/version");
    } catch (_error) {
      await delay(100);
    }
  }
  throw new Error("Chrome DevTools endpoint did not start");
}

function percentile(values, percentileRank) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.ceil((percentileRank / 100) * sorted.length) - 1];
}

function summarize(samples) {
  return {
    input_p95_ms: percentile(
      samples.map((sample) => sample.inputMs),
      95,
    ),
    restore_p95_ms: percentile(
      samples.map((sample) => sample.restoreMs),
      95,
    ),
    retained_heap_p95_bytes: percentile(
      samples.map((sample) => sample.heapBytes),
      95,
    ),
  };
}

function percentChange(baseline, instrumented) {
  return ((instrumented - baseline) / baseline) * 100;
}

await waitForChrome();
const target = await debuggingEndpoint("/json/new?about:blank");
const socket = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener("open", resolve, { once: true });
  socket.addEventListener("error", reject, { once: true });
});

let commandId = 0;
const pending = new Map();
socket.addEventListener("message", (event) => {
  const message = JSON.parse(event.data);
  if (message.method === "Page.javascriptDialogOpening") {
    void command("Page.handleJavaScriptDialog", { accept: true });
    return;
  }
  if (!message.id) return;
  const callbacks = pending.get(message.id);
  if (!callbacks) return;
  pending.delete(message.id);
  if (message.error) callbacks.reject(new Error(message.error.message));
  else callbacks.resolve(message.result);
});

function command(method, params = {}) {
  commandId += 1;
  return new Promise((resolve, reject) => {
    pending.set(commandId, { resolve, reject });
    socket.send(JSON.stringify({ id: commandId, method, params }));
  });
}

async function evaluate(expression, awaitPromise = false) {
  const result = await command("Runtime.evaluate", {
    expression,
    awaitPromise,
    returnByValue: true,
  });
  if (result.exceptionDetails)
    throw new Error(result.exceptionDetails.exception?.description || "Evaluation failed");
  return result.result.value;
}

async function sample(telemetryEnabled) {
  const url = new URL(baseUrl);
  if (!telemetryEnabled) url.searchParams.set("telemetry", "off");
  await command("Page.navigate", { url: url.href });
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if ((await evaluate("document.readyState")) === "complete") break;
    await delay(20);
  }
  await evaluate(`new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)))`, true);
  let editorFound = false;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    editorFound = await evaluate(
      `Boolean(document.querySelector('[contenteditable="true"]'))`,
    );
    if (editorFound) break;
    await delay(20);
  }
  if (!editorFound) throw new Error(`Editor was not found at ${url.href}`);
  const restoreMs = await evaluate("performance.now()");
  await evaluate(`(() => {
    const editor = document.querySelector('[contenteditable="true"]');
    editor.focus();
    const selection = window.getSelection();
    selection.selectAllChildren(editor);
    selection.collapseToEnd();
    window.__authoringInputSample = new Promise((resolve) => {
      const startedAt = performance.now();
      requestAnimationFrame(() => requestAnimationFrame(() => resolve(performance.now() - startedAt)));
    });
  })()`);
  await command("Input.insertText", { text: "x" });
  const inputMs = await evaluate("window.__authoringInputSample", true);
  await command("HeapProfiler.collectGarbage");
  const heapBytes = await evaluate("performance.memory.usedJSHeapSize");
  return { inputMs, restoreMs, heapBytes };
}

try {
  await command("Page.enable");
  await command("Runtime.enable");
  await command("HeapProfiler.enable");
  const samples = { baseline: [], instrumented: [] };
  for (let index = 0; index < runs; index += 1) {
    const order = index % 2 === 0 ? [false, true] : [true, false];
    for (const enabled of order) {
      samples[enabled ? "instrumented" : "baseline"].push(
        await sample(enabled),
      );
      process.stderr.write(
        `completed ${index + 1}/${runs} ${enabled ? "instrumented" : "baseline"}\n`,
      );
    }
  }
  const baseline = summarize(samples.baseline);
  const instrumented = summarize(samples.instrumented);
  const changePercent = Object.fromEntries(
    Object.keys(baseline).map((key) => [
      key,
      percentChange(baseline[key], instrumented[key]),
    ]),
  );
  process.stdout.write(
    `${JSON.stringify({ runs, baseline, instrumented, change_percent: changePercent }, null, 2)}\n`,
  );
} finally {
  socket.close();
  chrome.kill("SIGTERM");
  await rm(profilePath, { recursive: true, force: true });
}
