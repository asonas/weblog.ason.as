import assert from "node:assert/strict";
import test from "node:test";
import { histogramMetric, valueBucket } from "./performanceTelemetry";

test("builds a bounded explicit histogram", () => {
  assert.deepEqual(
    histogramMetric("authoring.interaction.duration", [3, 20, 220]),
    {
      name: "authoring.interaction.duration",
      unit: "ms",
      count: 3,
      sum: 243,
      min: 3,
      max: 220,
      explicit_bounds: [4, 16, 50, 100, 200, 500, 1000, 5000],
      bucket_counts: [1, 0, 1, 0, 0, 1, 0, 0, 0],
    },
  );
});

test("uses fixed buckets for page characteristics", () => {
  assert.equal(valueBucket(0), "0");
  assert.equal(valueBucket(32), "11-100");
  assert.equal(valueBucket(32_255), "10001+");
});
