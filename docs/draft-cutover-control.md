# Draft cutover control rehearsal

This is the control plane for #172. Production API/worker factories and opt-in
Terraform routing are connected, but all activation flags default to false.
Nothing in this document authorizes deployment or changes to production data.
Use the separately approved [production runbook](draft-cutover-runbook.md).
Passing tests is not evidence that production writers have stopped.

## Phase boundaries

| Phase | Reader source | Article writes | Publication/repair admission |
| --- | --- | --- | --- |
| `legacy` | Legacy articles | Legacy protocol only | Legacy publisher |
| `draining` | Legacy articles | Neither protocol | Legacy publisher, to settle pending work |
| `frozen` | Legacy articles | Neither protocol | None |
| `preparing` | Legacy articles | Neither protocol | Published output repair |
| `verifying` | Published snapshots | Neither protocol | Published output repair |
| `open` | Published snapshots | Draft protocol only | Published output repair |
| `paused` | Published snapshots | Neither protocol | None |

Normal transitions are `legacy → draining → frozen → preparing → verifying → open`.
Before opening, `draining`, `frozen`, `preparing` and `verifying` can return to `legacy` after
verification. After opening, only `open ↔ paused` is permitted. Reopening seals the
migration and changes the phase in the same transaction; import cannot overwrite
new editing even if a later repair requires maintenance.

`DraftStore#setup_cutover!` explicitly creates two control tables in addition to
the existing 25 draft/migration/publication tables. Normal `setup!` does not initialize
them. `cutover_status` returns the phase, operator evidence, migration fingerprint
and in-flight operation receipts. No public endpoint can change the phase.

## Admission and draining

`DraftCutoverApi` receives two fully assembled APIs, `legacy` and `published`, plus
their shared control store. The published API must use `DraftReader`, the draft
publisher, outputs and jobs. `DraftRuntime` assembles those dependencies for the
API and publication worker.

The wrapper registers legacy save/rename, draft mutations and scheduled publication
before invoking their API. Registration and transitions touch the same control row,
so a concurrent phase change must conflict or observe the registered operation.
The database transaction ends before running the API, renderer or other external
work. An admitted operation finishes on the API chosen at admission, even if new
admissions are stopped while it is running.

Stopping admission does not cancel requests already running. A transition out of
draining, frozen, preparing, verifying or paused requires zero registered operations. Normal
returns and exceptions release receipts. A process crash can leave a receipt; it
has no automatic TTL. Preserve it, establish that the exact invocation/process is
no longer running and inspect partial writes/publication before explicit recovery.
The operator command can remove only a named `draft_publication` receipt in
`preparing`, with evidence that the invocation ended and partial state was
preserved. There is no general force-clear, automatic expiry or automatic rollback.

During maintenance both write protocols return 503 `authoring_maintenance`.
Once editing has opened, legacy writes return 409 `upgrade_required`, including
while paused. Both responses are JSON with `Cache-Control: no-store`. Readers
continue using the phase's article source. Inbox/media operations are not article
writes and retain their existing flow.

## Operator evidence

`transition_cutover(expected:, to:, evidence:)` rejects stale expected phases.
The following evidence is required in addition to zero registered operations:

- To `frozen`: `legacy_writers_retired: true`, `legacy_generators_paused: true`,
  `pending_legacy_publications: 0` and a nonblank `record` identifying the evidence.
- To `preparing`: `source_preserved: true`, the exact imported `fingerprint` and a
  nonblank `record`. The migration must already be verified.
- To `verifying`: `published_outputs_ready: true`, `legacy_generators_paused: true`
  and a nonblank `record`. Verify article HTML, Atom and search before changing
  reader sources; keep legacy readers during output generation in `preparing`.
- To `open`: `reader_outputs_verified: true`, `legacy_generators_paused: true` and
  a nonblank `record`. The verified or sealed migration fingerprint must still
  match the one used for reader verification.
- Back to `legacy`: `legacy_state_verified: true` and a nonblank `record`.

These values are explicit operator attestations, **not automatic AWS checks**.
Before supplying them, preserve old tabs as described in
[Legacy editor cutover preparation](legacy-editor-cutover-preparation.md), confirm
that every writer/runtime and generator is gated or retired, inspect actual
pending site publication and scheduled/queue invocation state, and keep the
source snapshot plus its fingerprint. A previously deployed ungated Lambda or
direct worker cannot be stopped by this wrapper. The retired-writer evidence must
include those runtime versions and any already-running invocation.

Settling site publication never permits outbound Webmention delivery. Preserve
unsent delivery state and keep sending disabled; do not use an outbound delivery
queue's emptiness as the drain criterion. Old scheduled/background generators must
be paused separately and confirmed inactive before declaring them paused here.

Rollback changes admission and reader selection only: it neither restores nor
deletes article data. Before returning to legacy, verify that its preserved state
still matches the intended source and that no new editing was opened. Keep the
unused imported destination for diagnosis. If legacy editing changes the source
after rollback, do not reset fingerprints or reuse that destination for a different
import; a later migration needs a separately scoped destination/recovery decision.
After opening, preserve new work and repair forward; no transition revives legacy
writes or resets the migration seal.

## Verification and remaining boundaries

`test/authoring/test_draft_cutover.rb` uses real SQLite stores and APIs to verify
in-flight draining, writer rejection, reader continuity, pre-open rollback,
atomic opening/sealing and post-open retention. These tests change no cloud resources.
The separately authorized `test/fixtures/drafts/verify_dsql_publication.rb` uses
27 tables in a randomly named verification schema, including both control tables.
It exercises stale admission against a concurrent maintenance transition with
actual DSQL OCC retries, opening/sealing and rejection of post-open rollback.
It checks the table allowlist before removing the isolated schema. This does not
measure production traffic or prove that deployed workers use this control.

`test/authoring/test_draft_runtime.rb` rehearses the assembled runtime: preserved
legacy HTML/feed, pre-open rollback, published HTML/Atom/search, asynchronous
dispatch/polling, rejected legacy writes, retained unsent outbox and post-open
retention. Lambda invocation is substituted at the AWS boundary; SQLite, Yjs,
QMD and generated artifacts are real. See the runbook for deployment-only gaps,
resource/cost evidence and explicit activation approvals.
