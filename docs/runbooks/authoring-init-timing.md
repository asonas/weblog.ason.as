# Authoring initialization timing

## Parameter Store extension comparison

The authoring handler reads OAuth configuration through the AWS Parameters and Secrets Lambda Extension during INVOKE. `secrets_client` now measures construction of the local HTTP adapter; `secret_get` includes the extension's first Parameter Store request. Keep `sqs_client` in the comparison to detect initial SDK work moving to SQS. The memory setting remains 512 MB.

The application still keeps its OAuth configuration for the life of its execution environment. The extension's cache TTL does not change that existing refresh behavior.

Before building `Dockerfile.lambda`, run `python3 scripts/prepare-parameter-extension.py` with AWS credentials permitted to read the pinned public layer. The script verifies its SHA-256 and extracts its executable into `dist/parameter-extension`; the Dockerfile copies it into `/opt`. The authoring image is shared by other Ruby Lambda entry points, so check their deployment smoke tests as well.

Apply the `infra/bootstrap` permission for the pinned layer before deploying the image through GitHub Actions. Do not attach a Lambda layer to this image-based function. To upgrade the extension, update the script's ARN and checksum and the matching IAM resource together.

After deployment, compare natural cold invocations against the baseline (SSM client construction approximately 5–6 seconds). Join `cold_api_timing`, `cold_require_timing` and REPORT by request ID, compare total billed GB-seconds as well as client timings, and confirm successful `/api/pages` and `/api/auth/session` responses. Also check warm invocations and extension error logs. A fast local adapter construction alone does not establish a production improvement.

References: [AWS extension protocol and INVOKE restriction](https://docs.aws.amazon.com/systems-manager/latest/userguide/ps-integration-lambda-extensions.html), [extensions in container images](https://docs.aws.amazon.com/lambda/latest/dg/extensions-configuration.html).

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
