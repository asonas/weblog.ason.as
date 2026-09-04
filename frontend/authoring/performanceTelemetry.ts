const HISTOGRAM_BOUNDS = [4, 16, 50, 100, 200, 500, 1000, 5000];
export const AUTHORING_TELEMETRY_FLUSH_EVENT =
  "weblog:authoring-telemetry-flush";

type Metric = {
  name: string;
  unit: string;
  count?: number;
  sum?: number;
  min?: number;
  max?: number;
  explicit_bounds?: number[];
  bucket_counts?: number[];
  value?: number;
};

type TelemetrySpan = {
  name: "authoring.session.restore";
  duration_ms: number;
  attributes: Record<string, string | boolean>;
};

export type PerformanceTelemetryBatch = {
  schema_version: "1.0";
  resource: { attributes: Record<string, string | number | boolean> };
  metrics: Metric[];
  spans: TelemetrySpan[];
};

type StartOptions = {
  body: string;
  csrfToken: string;
  environment: string;
  serviceVersion: string;
};

type FlushEvent = CustomEvent<{ body?: string; saveDurationMs?: number }>;

type MemoryPerformance = Performance & {
  memory?: { usedJSHeapSize: number };
};

type DiscardableDocument = Document & { wasDiscarded?: boolean };

export function valueBucket(value: number): string {
  if (value === 0) return "0";
  if (value <= 10) return "1-10";
  if (value <= 100) return "11-100";
  if (value <= 1_000) return "101-1000";
  if (value <= 10_000) return "1001-10000";
  return "10001+";
}

export function histogramMetric(name: string, values: number[]): Metric | null {
  if (values.length === 0) return null;
  const bucketCounts = Array.from(
    { length: HISTOGRAM_BOUNDS.length + 1 },
    () => 0,
  );
  for (const value of values) {
    const index = HISTOGRAM_BOUNDS.findIndex((bound) => value <= bound);
    bucketCounts[index === -1 ? HISTOGRAM_BOUNDS.length : index] += 1;
  }
  return {
    name,
    unit: "ms",
    count: values.length,
    sum: values.reduce((total, value) => total + value, 0),
    min: Math.min(...values),
    max: Math.max(...values),
    explicit_bounds: HISTOGRAM_BOUNDS,
    bucket_counts: bucketCounts,
  };
}

export function startAuthoringPerformanceTelemetry(
  options: StartOptions,
): () => void {
  const interactions = new Map<number, number>();
  const durations = new Map<string, number[]>();
  const requestCounts = new Map<string, number>();
  const spans: TelemetrySpan[] = [];
  const observers: PerformanceObserver[] = [];
  let latestBody = options.body;
  let stopped = false;
  const wasDiscarded = Boolean((document as DiscardableDocument).wasDiscarded);

  const recordDuration = (name: string, duration: number) => {
    const values = durations.get(name) || [];
    values.push(duration);
    durations.set(name, values);
  };

  const observe = (
    type: string,
    callback: (entry: PerformanceEntry) => void,
  ) => {
    if (!PerformanceObserver.supportedEntryTypes.includes(type)) return;
    const observer = new PerformanceObserver((list) =>
      list.getEntries().forEach(callback),
    );
    observer.observe({ type, buffered: true });
    observers.push(observer);
  };

  observe("event", (entry) => {
    const interactionId =
      "interactionId" in entry ? Number(entry.interactionId) : 0;
    if (interactionId > 0)
      interactions.set(
        interactionId,
        Math.max(interactions.get(interactionId) || 0, entry.duration),
      );
  });
  observe("longtask", (entry) =>
    recordDuration("authoring.long_task.duration", entry.duration),
  );
  observe("resource", (entry) => {
    if (!entry.name.includes("/api/")) return;
    if (entry.name.includes("/api/embed")) {
      recordDuration("authoring.requests.embed.duration", entry.duration);
      requestCounts.set(
        "authoring.requests.embed.total",
        (requestCounts.get("authoring.requests.embed.total") || 0) + 1,
      );
    }
  });

  if (wasDiscarded) {
    spans.push({
      name: "authoring.session.restore",
      duration_ms: performance.now(),
      attributes: {
        "session.discarded": true,
        "navigation.type":
          (
            performance.getEntriesByType("navigation")[0] as
              | PerformanceNavigationTiming
              | undefined
          )?.type || "unknown",
      },
    });
  }

  const flush = async () => {
    if (stopped) return;
    try {
      const storageStartedAt = performance.now();
      sessionStorage.setItem("weblog:telemetry-probe", "1");
      sessionStorage.removeItem("weblog:telemetry-probe");
      recordDuration(
        "authoring.session_storage.duration",
        performance.now() - storageStartedAt,
      );
    } catch (_error) {
      // Storage can be unavailable in restricted browser contexts.
    }
    const interactionValues = [...interactions.values()];
    interactions.clear();
    if (interactionValues.length > 0)
      durations.set("authoring.interaction.duration", interactionValues);

    const metrics = [...durations.entries()]
      .map(([name, values]) => histogramMetric(name, values))
      .filter((metric): metric is Metric => metric !== null);
    durations.clear();
    requestCounts.forEach((value, name) => {
      metrics.push({ name, unit: "{request}", value });
    });
    requestCounts.clear();
    metrics.push({
      name: "authoring.dom.nodes",
      unit: "{node}",
      value: document.getElementsByTagName("*").length,
    });
    metrics.push({
      name: "authoring.frames",
      unit: "{frame}",
      value: document.querySelectorAll("iframe").length,
    });
    metrics.push({
      name: "authoring.documents",
      unit: "{document}",
      value: 1 + document.querySelectorAll("iframe").length,
    });
    const heap = (performance as MemoryPerformance).memory?.usedJSHeapSize;
    if (heap !== undefined)
      metrics.push({
        name: "authoring.js_heap.bytes",
        unit: "By",
        value: heap,
      });

    const batch: PerformanceTelemetryBatch = {
      schema_version: "1.0",
      resource: {
        attributes: {
          "service.name": "weblog-authoring",
          "service.version": options.serviceVersion,
          "deployment.environment.name": options.environment,
          "browser.time_origin_unix_ms": performance.timeOrigin,
          "session.discarded": wasDiscarded,
          "navigation.type":
            (
              performance.getEntriesByType("navigation")[0] as
                | PerformanceNavigationTiming
                | undefined
            )?.type || "unknown",
          "page.body_length_bucket": valueBucket(latestBody.length),
          "page.external_link_count_bucket": valueBucket(
            (latestBody.match(/https?:\/\//g) || []).length,
          ),
          "page.image_count_bucket": valueBucket(
            (latestBody.match(/!\[/g) || []).length,
          ),
          "page.wiki_link_count_bucket": valueBucket(
            (latestBody.match(/\[\[/g) || []).length,
          ),
        },
      },
      metrics,
      spans: spans.splice(0),
    };

    try {
      await fetch("/api/authoring/telemetry", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": options.csrfToken,
        },
        body: JSON.stringify(batch),
        keepalive: true,
      });
    } catch (_error) {
      // Telemetry must not affect authoring.
    }
  };

  const interval = window.setInterval(() => void flush(), 60_000);
  const handlePageHide = () => void flush();
  const handleBatchBoundary = (event: Event) => {
    const detail = (event as FlushEvent).detail;
    if (detail?.body !== undefined) latestBody = detail.body;
    if (detail?.saveDurationMs !== undefined) {
      recordDuration("authoring.requests.save.duration", detail.saveDurationMs);
      requestCounts.set(
        "authoring.requests.save.total",
        (requestCounts.get("authoring.requests.save.total") || 0) + 1,
      );
    }
    void flush();
  };
  window.addEventListener("pagehide", handlePageHide);
  window.addEventListener(AUTHORING_TELEMETRY_FLUSH_EVENT, handleBatchBoundary);
  if (wasDiscarded) void flush();
  return () => {
    window.clearInterval(interval);
    window.removeEventListener("pagehide", handlePageHide);
    window.removeEventListener(
      AUTHORING_TELEMETRY_FLUSH_EVENT,
      handleBatchBoundary,
    );
    observers.forEach((observer) => {
      observer.disconnect();
    });
    void flush().finally(() => {
      stopped = true;
    });
  };
}
