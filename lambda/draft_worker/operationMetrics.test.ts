import assert from "node:assert/strict";
import test, { afterEach, beforeEach } from "node:test";
import { measureOperation, measureQuery } from "./operationMetrics.js";

let previous: Record<string, string | undefined>;
beforeEach(() => {
  previous = {
    OPERATION_METRICS_SAMPLE_RATE: process.env.OPERATION_METRICS_SAMPLE_RATE,
    OPERATION_METRICS_UNTIL: process.env.OPERATION_METRICS_UNTIL,
  };
});
afterEach(() => {
  for (const [key, value] of Object.entries(previous)) {
    if (value === undefined) delete process.env[key];
    else process.env[key] = value;
  }
});

test("sampled operations retain results and errors without SQL or document content", async (t) => {
  process.env.OPERATION_METRICS_SAMPLE_RATE = "1";
  process.env.OPERATION_METRICS_UNTIL = String(Date.now() / 1000 + 60);
  const output: string[] = [];
  t.mock.method(console, "log", (line: string) => output.push(line));
  assert.equal(
    await measureOperation("draft_publication", "first", async () => {
      await measureQuery("BEGIN", async () => undefined);
      return measureQuery("SELECT secret", async () => "private-body");
    }),
    "private-body",
  );
  await assert.rejects(
    measureOperation("draft_maintenance", "second", () =>
      measureQuery("DELETE private", async () => {
        throw new Error("private-error");
      }),
    ),
  );
  const first = JSON.parse(output[0]);
  const second = JSON.parse(output[1]);
  assert.equal(first.sql_count, 1);
  assert.equal(first.failed, false);
  assert.equal(second.sql_count, 1);
  assert.equal(second.sql_errors, 1);
  assert.equal(second.failed, true);
  assert.ok(output.every((line) => Buffer.byteLength(line) < 1024));
  assert.doesNotMatch(output.join(""), /secret|private|SELECT|DELETE/);
});

test("an expired or disabled sample produces no additional output", async (t) => {
  const log = t.mock.method(console, "log", () => undefined);
  process.env.OPERATION_METRICS_SAMPLE_RATE = "1";
  process.env.OPERATION_METRICS_UNTIL = "0";
  assert.equal(
    await measureOperation("draft_maintenance", "one", async () => 42),
    42,
  );
  process.env.OPERATION_METRICS_UNTIL = String(Date.now() / 1000 + 60);
  process.env.OPERATION_METRICS_SAMPLE_RATE = "0";
  await measureOperation("draft_maintenance", "two", async () => 42);
  assert.equal(log.mock.callCount(), 0);
});
