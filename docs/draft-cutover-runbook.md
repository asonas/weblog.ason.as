# Draft cutover: rehearsal and production approval

This completes the tooling/rehearsal boundary of #172, not production activation.
Do not run the mutation examples until the user approves their exact scope.
Outbound Webmention stays disabled throughout. Do not replay its queue.

## Exact scope

Account `282782318939`, region `ap-northeast-1`, site `https://weblog.ason.as`:

| Target | Purpose and mutation boundary |
| --- | --- |
| DSQL `zjuauvwetzvab4i3bdfd47e3yu.dsql.ap-northeast-1.on.aws` | Preserve `weblog_authoring.pages` and auxiliary tables; initialize/import into 27 `draft_*` tables and grant the existing database role access. No reverse migration or source deletion. |
| S3 `weblog-asonas-site-production-282782318939` | Preserve root article objects and root `feed.xml` for rollback; place new immutable HTML under `published/`, feed/manifests under `published-outputs/`, and search databases under the existing `search/` prefix. Keep bucket versioning enabled. |
| Lambda `weblog-authoring-production` | Phase-controlled reader and both write protocols; asynchronous publication dispatch. |
| Lambda `weblog-search-indexer-production` | Existing Node/QMD image handles new publication/repair; concurrency 1. Legacy SQS work is separately gated. |
| Lambda `weblog-webmention-publisher-production` | Gate legacy publishing; force outbound sending false while cutover is enabled. |
| Lambda/ECR/log group `weblog-draft-worker-production` | Previously specified compaction worker; it is still unprovisioned in the inspected production state. Read-only publication reconstruction is separate from gated scheduled compaction. |
| API Gateway `hm9v1d16ti` | Six opt-in routes for draft APIs and public GET/HEAD. Existing specific API routes remain. |
| CloudFront `E3BCWEKGAG5LSG` | Switch default article origin to the API without caching pointer responses; keep `/assets/*`, `/static/*` and known static files on S3. Serve `/draft-offline.js` without CDN caching. |
| EventBridge `weblog-rss-feed-production` | Retain the hourly rule and authoring target. The gated runtime chooses legacy feed generation before cutover and asynchronous published-output repair afterwards. |
| EventBridge `weblog-search-index-nightly-production`, `weblog-webmention-outbox-dispatch-production` | Disable with the corresponding search/publisher SQS mappings after draining. Preserve queue contents and DLQs. |
| EventBridge `weblog-draft-worker-production` | Enable hourly compaction only after reopening. |

Do not alter inbox schedules, incoming verification, cleanup, outbound queues,
or other account resources as part of this change. The outbox count below concerns
site publication, not outbound delivery readiness.

## Read-only inventory on 2026-09-20

- Production: 843 published named articles, 1,035,220 total Markdown bytes,
  largest 33,335 bytes. No date-type article with a separate display title.
- Site-publication outbox: 841 completed, 1,685 superseded, zero pending.
  This is a point-in-time observation, **not** evidence for a later maintenance window.
- Production publisher has `WEBMENTION_SENDER_ENABLED=false`.
- CloudFront total requests, 2026-08-20 through 2026-09-20 UTC: 109,740.
- Local preserved-source rehearsal: 821 articles, initial import and rerun passed.
  It is not the production snapshot. Preserve `/tmp/weblog-migration-ZQ7Ue8/`
  until the user decides how to retain or remove the private artifacts.

The authoring-production SSO role could not `dsql:DbConnect`; inventory therefore
used the admin role with SELECT-only queries. Do not widen IAM merely to make an
inventory command work.

## Approval gates and order

1. Obtain separate approval for provisioning/deploying the inactive prerequisite
   worker and these gated images. Build/push the worker image before creating its
   Lambda; the configured `:bootstrap` image must exist. Keep activation flags false.
   Follow the repository's existing ECR bootstrap/runbook rather than applying a
   plan that creates a Lambda before its image exists.
2. Inventory all open/suspended/offline editor tabs and preserve unsaved content
   using [the legacy editor procedure](legacy-editor-cutover-preparation.md).
   Agree a deployment freeze for the migration window, and record current Lambda
   image digests, aliases, S3 version IDs for shells/feed/article objects, schedules,
   SQS mappings, message counts and in-flight invocations. Unknown tabs or ungated
   historical versions that can still be invoked block the cutover.
3. With explicit database approval, initialize the draft/control schema. Verify
   all new tables and runtime IAM-to-database bindings before enabling the runtime.
   `initialize` is idempotent, does not import articles, and does not reopen editing.
4. Deploy gated code to authoring, search and legacy publisher; activate
   `draft_cutover_enabled=true` while the database phase is still `legacy`.
   Keep `draft_reader_routing_enabled=false`, `legacy_generators_paused=false`,
   `draft_maintenance_enabled=false`. Verify old save/rename and generators use
   the control row. Wait for old ungated invocations to finish and retire their
   invocation paths. Do not infer this from deployment success alone.
5. Enter `draining`. Legacy and draft mutations now return maintenance; readers
   continue. Wait for operation receipts, pending site outbox and search/publication
   queue work to settle. Do not drain outbound Webmention delivery. Then set
   `legacy_generators_paused=true`, confirm both SQS mappings Disabled, legacy
   rules Disabled and no active invocation. Enter `frozen` with recorded evidence.
6. Export the frozen source to a new 0600 JSON file; preserve it outside temporary
   storage together with its fingerprint and the legacy S3/version inventory.
   Import with that exact fingerprint, then rerun to verify idempotence. The
   matching public/working versions retain identity, Markdown, metadata, route,
   timestamps and old Atom IDs; migration does not create new publication dates.
7. Enter `preparing`, which leaves readers on legacy. Generate HTML/Atom/search
   with the new worker. Verify every active snapshot's HTML object/digest and the
   output heads' revision/digest, including search retrieval. A worker timeout or
   retained operation receipt is a stop condition. Preserve the partial output,
   prove that the exact invocation has ended and use the bounded recovery command;
   never delete or broadly clear receipts.
   Measure full-corpus first-build duration in this window; isolated fixture
   results do not prove all 843 articles finish within Lambda's 300 seconds.
   If the bound is exceeded, preserve partial output and plan bounded recovery
   before proceeding. The CLI import itself is not constrained by Lambda timeout.
8. Confirm the preserved fingerprint still matches the verified import. If another
   source export is required, perform the documented pre-open rollback and freeze
   sequence first; there is no direct `preparing → frozen` shortcut. Never replace
   the original file. A changed source needs a new migration decision, not editing
   the stored fingerprint.
9. With separate routing approval, set `draft_reader_routing_enabled=true` while
   legacy reading is selected. Wait for CloudFront deployment and invalidate old
   article/feed cache entries using the exact distribution. Check legacy reads
   through the new route first; then enter `verifying`. Confirm article HTML,
   trailing-slash URLs, named/dated routes, tag hubs, reader APIs, Atom identities,
   search, media, redirects and edit links. No new writes are admitted yet.
10. Rehearse rollback **before** reopening: verify preserved legacy source/objects,
    return phase to `legacy`, verify readers, and repeat the maintenance/verification
    sequence using the unchanged input. If legacy edits occur after rollback,
    stop: the imported fingerprint cannot simply be reused or reset.
11. Obtain explicit reopen approval, record reader verification and enter `open`.
    This seals migration atomically. Confirm a draft edit stays private; explicitly
    publish the confirmed revision, wait for its dispatch, then verify HTML/feed/
    search and unchanged outbound state. Enable `draft_maintenance_enabled` only
    after this. Record the final untargeted infrastructure plan.

After reopening, use `open → paused` to stop mutations while keeping published
readers. Preserve all new Yjs updates, receipts, snapshots and dispatches. There
is no supported return to `legacy`, source overwrite, forced receipt clearing or
automatic reverse migration. Inspect partial work and repair forward, then reopen
with evidence. Keep both old and new artifacts until a separate retention decision.

## Operator tooling

Use `MISE_ACTIVATE_AGGRESSIVE=true mise exec --` for Ruby/Node and `mairu exec
--no-login` for AWS credentials. The CLI always targets the explicit host and
`weblog_authoring` schema; it does not modify Terraform, deploy images or pause
AWS schedules. Every mutating command requires both a matching `--confirm-host`
and an evidence JSON file with a nonempty `record`. Phase-specific evidence keys
are listed in [cutover control](draft-cutover-control.md).

```sh
MISE_ACTIVATE_AGGRESSIVE=true mise exec -- mairu exec --no-login --server asonas-aws 282782318939/AdministratorAccess -- ruby -rbundler/setup bin/draft-cutover status --host "$CUTOVER_HOST"
```

Following separate approval, the same command prefix supports:

```text
initialize --host HOST --confirm-host HOST --evidence APPROVAL.json
transition --host HOST --confirm-host HOST --from legacy --to draining --evidence EVIDENCE.json
export --host HOST --snapshot NEW_SOURCE.json --site-url https://weblog.ason.as
import --host HOST --confirm-host HOST --snapshot NEW_SOURCE.json --fingerprint SHA256 --evidence EVIDENCE.json
transition --host HOST --confirm-host HOST --from frozen --to preparing --evidence EVIDENCE.json
recover --host HOST --confirm-host HOST --operation-id RECEIPT --evidence EVIDENCE.json
```

`export`/`import` require frozen admission and register a migration operation so
phase transitions cannot race them. Read the result of each step; never chain the
whole cutover unattended. A malformed/unsupported source stops import. No command
overwrites an export or clears migration/control state. An interrupted import can
be rerun only with the same preserved input and unmodified destination.

`recover` removes only the named `draft_publication` receipt while the cutover is
in `preparing`. Its evidence must contain `operation_ended: true`,
`partial_state_preserved: true`, a nonempty Lambda `request_id` and a nonempty
`record`. Confirm the matching END/timeout log and preserve the partial stage and
output inventory before running it. Other operation kinds and phases cannot be
recovered with this command. Repair processes at most 50 articles per invocation;
repeat it until it returns `completed`, then verify that no receipt or unfinished
publication stage remains.

New repair is the `{"operation":"draft_repair"}` event for the search-indexer
Lambda, not the legacy search SQS queue. Scheduled hourly repair uses the same
path. Explicit publication returns a durable dispatch ID; the editor polls its
authenticated job endpoint, retains retry information on response loss, and does
not run Node/QMD inside the 15-second API Lambda.

## Rehearsal evidence and gaps

- Real SQLite/Yjs/QMD runtime test: source preservation, pre-open rollback, reader
  switch, legacy write rejection, chunked edit upload, asynchronous acceptance,
  dispatch polling, published HTML/Atom/search and post-open retention.
- Real DSQL: 32 checks including batch reads, dispatch completion/redelivery,
  migration, OCC admission, publication/rename activation, stage repair and cleanup.
  Isolated schema `draft_publish_verify_5b11e736a6e9` was removed.
- Node DSQL worker: gated admission, active receipt, compaction and cleanup of a
  1,300,029-byte deletion-only update; isolated `draft_verify_c553410c5f61` removed.
- Chrome: wide/narrow preview, publication/rename, asynchronous polling, output
  retry, lost-response recovery, editor reopen, management flow, offline reload,
  closed-tab reopen and reconnect. Production build emits the shell-only SW;
  caches do not include API responses, article HTML or drafts.
- Prior user confirmation covers Japanese IME commit/cancel, remote changes during
  composition, cursor preservation and Undo. This change did not repeat that on
  a physical device. Mobile coverage is desktop Chrome viewport emulation, not
  iOS Safari. No production traffic cutover, real AWS asynchronous delivery,
  full-corpus Lambda timing or human visual sign-off has been performed here.
  These are explicit production-approval checks, not claims of deployment success.

## Fresh infrastructure and cost evidence

On 2026-09-20, local Terraform 1.15.9 / AWS provider 6.61.0 plans were refreshed
against actual production state, without apply or state mutation. Preserve current
Webmention variables (`receiver`, `verification`, `publisher` true; `sender` false).
Default false values would otherwise propose unrelated changes to their current
settings. The plan using all four cutover flags true is an **approval aid, not a
one-step activation plan**: activation must follow the staged procedure above.

- Saved activation comparison: `/tmp/weblog-cutover-plan-NJlOKC/activation.tfplan`,
  18 additions, 11 updates, zero destruction. Ten additions are the previously
  specified but unprovisioned draft worker resources. New additions are six routes
  and two narrowly scoped runtime policies. Updates are CloudFront distribution/
  function; three Lambda environments/concurrency; two legacy EventBridge rules;
  two SQS mappings; S3 bucket and search SQS policies recomputed through dependencies.
- Final inactive plan `/tmp/weblog-cutover-plan-NJlOKC/prepared-final.tfplan`:
  10 additions (the unprovisioned prerequisite worker), zero updates, zero
  destruction. There are no changes to currently deployed resources while
  activation flags are false.
- No new always-on server, NAT gateway, load balancer, queue or DSQL cluster.
  Existing search worker performs publication; reserved concurrency is not
  provisioned concurrency. ECR images, logs and immutable outputs consume storage.
- The current Markdown corpus is about 1 MB, not multiple GB. Two initial text
  copies are still small; Yjs history, generated HTML/search and retained versions
  add to that and must be measured separately. No blanket deletion/lifecycle rule
  is added for draft state or publication artifacts.
- Lambda free-tier observation: 29,310.7765 / 400,000 GB-seconds and
  48,819 / 1,000,000 requests used. This is account-wide, point-in-time usage, not a
  guarantee that future work is free. API Gateway free allowance was not reported.
- Conservatively routing **all** 109,740 monthly CloudFront requests through a
  512 MiB API at 1 second each would add 54,870 GB-seconds and 109,740 Lambda calls;
  actual extra calls are fewer because assets stay on S3 and API calls already exist.
  A 1 GiB hourly worker averaging 10 seconds adds 7,200 GB-seconds/month; two such
  workers add 14,400. These are assumptions, not measured post-cutover timings.
  At the full 300-second limit, two hourly workers could add 432,000 GB-seconds,
  so timeouts/repeated repair cannot be treated as negligible.
- Tokyo AWS Price List lookup (`AmazonApiGateway`, `APN1-ApiGatewayHttpRequest`)
  returned USD 1.29/million for the first 300 million HTTP requests. The deliberately
  overcounted 109,740 extra monthly requests would be about USD 0.142/month before
  taxes and any allowance. This excludes DSQL DPUs, S3 operations, logs, storage
  and transfer; those depend on actual query and output volume. The measured
  Lambda usage plus the 1-second/API and 10-second/worker assumptions fit within
  the current monthly allowance, but full-month use by other workloads is unknown.

Use the [AWS Lambda pricing](https://aws.amazon.com/lambda/pricing/) and
[HTTP API pricing](https://aws.amazon.com/api-gateway/pricing/) pages plus a fresh
Tokyo Price List lookup before approval. Refresh plans and free-tier usage for the
actual date; do not apply a stale saved comparison or include unrelated drift.
