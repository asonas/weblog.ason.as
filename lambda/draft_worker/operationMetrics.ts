import { AsyncLocalStorage } from "node:async_hooks";
import { createHash } from "node:crypto";

type Metrics = {
  sql_count: number;
  sql_ms: number;
  sql_errors: number;
};
const active = new AsyncLocalStorage<Metrics>();

export async function measureOperation<T>(
  workload: string,
  requestId: string,
  run: () => Promise<T>,
): Promise<T> {
  const rate = Number(process.env.OPERATION_METRICS_SAMPLE_RATE ?? 0);
  const until = Number(process.env.OPERATION_METRICS_UNTIL ?? 0);
  const sample = createHash("sha256")
    .update(requestId)
    .digest()
    .readUInt32BE(0);
  if (
    !Number.isFinite(rate) ||
    rate <= 0 ||
    rate > 1 ||
    !Number.isFinite(until) ||
    until * 1000 <= Date.now() ||
    sample >= rate * 2 ** 32
  )
    return run();

  const metrics: Metrics = { sql_count: 0, sql_ms: 0, sql_errors: 0 };
  const started = performance.now();
  const timestamp = new Date().toISOString();
  let failed = true;
  return active.run(metrics, async () => {
    try {
      const result = await run();
      failed = false;
      return result;
    } finally {
      console.log(
        JSON.stringify({
          event: "operation_metrics",
          schema: 1,
          timestamp,
          request_id: requestId,
          function: process.env.AWS_LAMBDA_FUNCTION_NAME,
          code_revision: process.env.BUILD_CONTENT_HASH,
          workload,
          sample_rate: rate,
          ...metrics,
          sql_ms: Math.round(metrics.sql_ms * 1000) / 1000,
          db_retries: 0,
          failed,
          duration_ms: performance.now() - started,
        }),
      );
    }
  });
}

export async function measureQuery<T>(
  sql: string,
  run: () => Promise<T>,
): Promise<T> {
  const metrics = active.getStore();
  if (!metrics || /^(BEGIN|COMMIT|ROLLBACK)\s*;?\s*$/i.test(sql.trim()))
    return run();
  const started = performance.now();
  metrics.sql_count += 1;
  let succeeded = false;
  try {
    const result = await run();
    succeeded = true;
    return result;
  } finally {
    metrics.sql_ms += performance.now() - started;
    if (!succeeded) metrics.sql_errors += 1;
  }
}
