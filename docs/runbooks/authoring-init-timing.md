# Authoring initialization timing

Use this probe to investigate the cold critical path in Issue #78.

`cold_require_timing` records the sequential dependency loads in `lambda/authoring.rb` without changing their order. Each section includes any dependencies loaded transitively by that require. Sections do not overlap; a dependency already loaded by an earlier section will take almost no time in a later section.

Measurements are captured during module loading and emitted once, on the first invocation in that Ruby process. The log contains:

- `request_id`: Lambda invocation ID, for joining with `cold_api_timing` and the Lambda REPORT.
- `gateway_request_id`: API Gateway request ID when present; null for non-HTTP events.
- `route`: HTTP path when present; empty for non-HTTP events.
- `require_total_ms`: elapsed time around the dependency-loading loop.
- `timings`: elapsed milliseconds for each direct require, including its transitive loads.

No credentials, request bodies, or response bodies are logged. Warm invocations do not serialize or emit these measurements.

## Interpretation

1. Join the first invocation's `cold_require_timing` and REPORT by Lambda request ID.
2. Compare `require_total_ms` with REPORT `Init Duration`. Require time is a subset of Init; do not add the two together. The difference includes runtime startup and other unmeasured initialization work and is not proof of a specific AWS bottleneck.
3. Compare `cold_api_timing.timings.api_total` with REPORT `Duration`. API construction runs inside the handler, after Init, and is only part of invocation duration.
4. For each invocation, calculate `Init Duration + Duration` before calculating percentiles. Do not add section percentiles.

The `weblog_authoring/dsql_database` section currently includes Markdown/Rouge loading through Webmention dependencies. This probe can identify a heavy dependency group but cannot separate Rouge from the other loads inside that group. A later focused probe may be necessary.

The probe does not include time before the handler module starts loading, and it emits no captured measurement if dependency loading fails or the environment never receives an invocation. It is not a substitute for HTTP end-to-end latency or browser metrics.

## Verification after a separately approved deployment

Allow normal traffic to produce cold samples; do not generate a concurrency burst just to populate the logs. Query `/aws/lambda/weblog-authoring-production`:

```text
fields @timestamp, request_id, gateway_request_id, route, require_total_ms, timings
| filter event = "cold_require_timing"
| sort @timestamp desc
```

Check that one log appears for each successfully loaded process that receives an invocation, and no duplicate is emitted for its warm calls. Use the same time window for REPORT, API construction, and Gateway measurements. Keep samples from different deployments distinguishable when comparing results.

This is an Issue #78 diagnostic probe, not a new performance success criterion. Remove the require instrumentation and its one-time emission after the startup investigation is complete; retain the ordinary dependency order.
