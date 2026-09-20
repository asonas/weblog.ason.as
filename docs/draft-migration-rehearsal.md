# Draft migration rehearsal

This tool copies a preserved legacy snapshot into an isolated SQLite database.
It does not deploy, activate production readers, stop writers, change schedules,
apply Terraform, send Webmentions, or copy S3 objects. Production cutover remains
blocked until the reader/writer gates and the operating procedure in #172 are complete.

## Local procedure

Use the project's managed Ruby and Node runtimes and installed dependencies.
Create a private scratch directory with `mktemp -d /tmp/weblog-migration-XXXXXX`.
Substitute the returned absolute directory in the commands below.

```sh
MISE_ACTIVATE_AGGRESSIVE=true mise exec -- ruby -rbundler/setup bin/draft-migration export --database /absolute/path/to/legacy.sqlite3 --snapshot /absolute/scratch/source.json --site-url https://weblog.ason.as
MISE_ACTIVATE_AGGRESSIVE=true mise exec -- ruby -rbundler/setup bin/draft-migration check --snapshot /absolute/scratch/source.json
MISE_ACTIVATE_AGGRESSIVE=true mise exec -- ruby -rbundler/setup bin/draft-migration rehearse --snapshot /absolute/scratch/source.json --database /absolute/scratch/drafts.sqlite3
```

Export opens the source read-only and captures the article collection with one
SELECT. The JSON is created with mode 0600 and exclusive creation; an existing
snapshot is never overwritten. An immutable snapshot is not proof that production
writes and pending publication have settled. Do not use a development copy as the
production migration source.

`check` performs validation without touching a destination. Unsupported records,
oversized bodies, duplicate IDs/routes, invalid timestamps and invalid cover data
stop the import before articles are copied. Only legacy published articles are
supported; another legacy status requires an explicit migration decision.

`rehearse` creates a separate, mode-0600 SQLite file with a rehearsal application
ID. An existing database without that ID is refused. Repeat the command with the
same snapshot and destination to resume. The first import also binds the destination
to the normalized input fingerprint. Do not replace the snapshot to bypass a mismatch.
If creation fails before the application ID is recorded, inspect that incomplete
scratch file and use a fresh scratch destination; the command will not adopt it.

The command prints only the count and fingerprint, not article bodies. Treat both
the snapshot and the rehearsal database as private source data. They are retained
for inspection and recovery; the command never deletes either one.

## Preservation and recovery boundaries

- Preserve 32-character or UUID article identity, exact Markdown in the imported
  snapshot, display title, date URL, cover, creation and update timestamps.
- Build working Y.Text through the installed JavaScript Yjs implementation. Ruby
  stores opaque updates. Content equality uses the same CRLF-normalized hash as
  ordinary publication, while the copied snapshot retains original line endings.
- An absent legacy publication time follows the existing feed's creation-time
  fallback. Export retains all other timestamp strings without advancing them.
- Bind each imported article to its existing URL-shaped Atom entry ID permanently.
  Later renames change its link, not that identity. Newly created articles continue
  to use their UUID-shaped Atom identity.
- Commit each working document, initial published version, route, timestamps,
  migration receipt and Atom identity in one transaction. Completed bookkeeping
  allows the existing output repair to render HTML without publishing again.
  Advancing the internal collection revision invalidates derived-output caches;
  it does not advance reader timestamps or emit a feed publication event.
- Resume interrupted imports without replacing existing versions or CRDT updates.
  Changed input or edited destination articles cause a refusal, not an overwrite.
  Reverify working content and copied public metadata/timestamps before marking
  the import verified.
- `DraftStore#seal_migration` irreversibly prevents reimport after verified migration.
  It must be part of a future reopening gate; it is not itself an API maintenance
  gate or proof that writers have been stopped. After reopening, preserve new data
  and repair forward. Never reset this marker or copy the old snapshot over new work.

The migration code has no S3, SQS, deployment or Webmention sender client. Generated
HTML, feed and search must be repaired and checked before any production reader
switch. This local tool does not yet perform that switch or its pre-reopen rollback.

## Published reader preparation

The opt-in admission state machine and pre-/post-reopen boundaries are described
in [Draft cutover control rehearsal](draft-cutover-control.md). It is not wired to
production and does not replace operational drain evidence.

`DraftReader` reads article bodies and metadata exclusively from active published
snapshots. Its list windows, timeline, tags, related pages and diary navigation do
not read working versions or fall back to legacy articles. Image dimensions and
approved incoming Webmentions still come from the existing auxiliary database.

Inject this reader as `LambdaApi`'s `reader_database` and as `DraftPublisher`'s
`database` when assembling an isolated cutover rehearsal. The API then returns
404 for unpublished IDs, including IDs also present in the legacy database.
Unknown routes retain the existing empty link-hub response. Old Scrapbox line
timestamps are not attached to a newly published body.

This injection is not a cutover gate: it does not stop either writer, configure
Atom/search jobs, or activate the production factory. Those must be connected and
verified together before production activation. The default factory is unchanged.

## Verification

`test/authoring/test_draft_migration.rb` covers preservation, Atom IDs after rename,
repair without republication, partial import resume, invalid-input rejection,
source/destination protection through the actual command, and post-edit/reopen
reimport refusal. `test/fixtures/drafts/verify_dsql_publication.rb` also verifies
initialization/rerun/sealing in a randomly named isolated DSQL schema. Its 26-table
allowlist includes the three migration/identity tables and two cutover-control
tables; cleanup checks that no
unexpected table is present and confirms the schema is gone. Running that external
DDL requires the separately approved isolated-test scope.

`test/authoring/test_draft_reader.rb` exercises the opt-in reader APIs, published
HTML repair, pagination and diary navigation with real SQLite stores, including
conflicting legacy content and unpublished metadata changes.

These checks do not demonstrate a production drain, maintenance gate, complete
reader/schedule cutover, real-device IME/mobile behavior, or production visual parity.
