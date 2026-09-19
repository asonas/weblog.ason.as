# Draft authoring development

This is the first implementation slice of [the draft authoring specification](https://github.com/asonas/weblog.ason.as/issues/161), tracked in [Create, save and resume drafts](https://github.com/asonas/weblog.ason.as/issues/162). It does not replace the legacy editor or enable production draft writes.

## Local use

Run the backend with `AUTHORING_DRAFTS_ENABLED=1 mise exec -- ruby -S bundle exec ruby bin/authoring`, then the frontend with `mise exec -- npm run dev`. Open `/draft-editor`. Its URL receives a stable draft ID; keep that URL to reopen the draft until the administration list is implemented.

The development backend stores drafts separately in `data/development/drafts.sqlite3`. It inherits the existing loopback-only development authentication configuration. When GitHub authentication is configured, draft reads require login and writes also require CSRF verification. Without OAuth configuration, only the explicitly enabled loopback development instance allows unauthenticated access. The Lambda API requires authentication for all draft operations and defaults to disabled unless a store is injected. No production handler, route, infrastructure or sender configuration is enabled here.

Native Markdown input and metadata are persisted in IndexedDB; a separate message reports durable server acknowledgment. Do not interpret a server receipt as semantic validation of Yjs. Ruby verifies the transport digest and declared body size but stores opaque updates. The browser enforces the 512 KiB Markdown bound without truncation. Trusted reconstruction and authoritative publication validation belong to the subsequent publication/compaction slices.

Updates use stable IDs and digests, atomic head/receipt/payload commits and bounded fixed-high-water catch-up. The browser declares an immutable upload manifest, sends at most 256 KiB decoded per request and asks for a receipt only after every ordered chunk reassembles to the declared digest. Chunk acknowledgments are not durable-sync receipts. Incomplete uploads do not advance the document head; identical chunks can resume, while different content at an existing position conflicts. The completed logical update is bounded to 2 MiB and stored atomically in 128 KiB rows. Successful commits remove their transport staging rows. The worker reclaims abandoned staging rows after seven days.

The PostgreSQL adapter accepts an Aurora DSQL pool with OCC retries. The canonical DSQL bootstrap now creates the draft, upload and checkpoint tables. Production Terraform defines a separate ARM64 Node.js Lambda image, least-privilege DSQL role, one-concurrent-worker bound and hourly EventBridge rule. The rule is deliberately provisioned `DISABLED`; applying the infrastructure does not authorize compaction, migration or draft writes.

## Verification

- API integration: `mise exec -- ruby -S bundle exec ruby -Itest test/authoring/test_drafts.rb`
- Browser integration: `mise exec -- node test/browser/draft_editor.mjs`
- Type checks: `mise exec -- npm run typecheck` and `mise exec -- ruby -S bundle exec steep check`

The browser test requires installed Chrome and permission to bind loopback ports 18082 and 15182. It starts an isolated temporary SQLite backend and Vite, verifies IndexedDB and fresh-browser recovery, selective local Undo/Redo, delayed acknowledgment with intervening edits, resumable upload identity, explicit recovery into a new isolated draft, oversized-input retention and public-data isolation, then stops its child servers. It does not contact AWS or use the author's real draft database.

## Delivery boundaries

The first part of [offline recovery and conflict merging](https://github.com/asonas/weblog.ason.as/issues/163) adds automatic retries for network failures and HTTP 408/429/5xx, retaining the persisted update ID after a lost response. Requests time out after 15 seconds. Authentication, validation and conflict errors pause background retries; the explicit retry button remains available. Visible editors check for server changes every 10 seconds and on focus/reconnection. Sending starts after 1 second idle or 5 seconds of continuous input, subject to an already-running request or composition.

Incoming body updates are deferred during composition. Browser coverage exercises API-disconnected reload from IndexedDB, reconnect, lost-response retry, a non-JSON 502, authentication failure, remote refresh, continuous input, synthetic composition and local-only Undo. API-disconnected reload assumes that the application shell remains available; offline asset caching is not implemented. Synthetic composition events do not establish real Japanese IME or mobile menu behavior.

Metadata changes to independent fields merge automatically. Concurrent changes to the same field retain the local value and the current server revision, and offer an explicit local/server choice. Conflicts survive reload. A confirmed metadata rejection clears the rejected flight while retaining its unsent body updates, then fetches the current server state before asking for a choice. An ambiguous network failure never clears that flight. Browser coverage includes offline title conflicts across separate browser contexts, reload, keyboard selection, a metadata race after sending starts, and independent title/type changes.

Same-browser tabs merge each IndexedDB write with the current stored record in one read/write transaction. Body state is merged with Yjs; pending updates are changed relative to the writer's previous snapshot, so a stale tab cannot remove another tab's work or revive acknowledged updates. BroadcastChannel notifies other tabs to reload the durable state; notifications are deferred during composition. Web Locks serialize server synchronization for each draft, including catch-up on opening. Closing a sender leaves the persisted flight available for another tab to retry with the same ID. Concurrent local metadata candidates are retained for explicit selection, including candidates not yet seen by a tab resolving an older conflict.

Browser verification covers two tabs editing while the API is disconnected, immediate propagation, local-only Undo/Redo, reload of both tabs, local metadata conflicts and a sender closing after losing its response. A fresh browser context verifies the resulting server body. These paths require Web Locks and BroadcastChannel; there is no unsafe unlocked fallback.

The browser test injects `QuotaExceededError` at the IndexedDB write boundary. It verifies that text remains editable, the storage warning appears, Markdown download preserves the exact body, and no update is sent before durable local storage succeeds. After storage recovers, retry persists the failed changes before synchronization; reload and a fresh browser context both recover the body. This simulates the storage error rather than filling the user's disk. When synchronization is stopped by an error, an explicit recovery action copies the current Markdown and metadata into a new draft ID. The old draft and server state remain untouched, so an obsolete tab cannot write into the recovered draft. This is a recovery generation boundary, not an implicit reset or deletion.

Real Japanese IME/mobile menu Undo validation and publication remain unfinished. No administration UI is implemented here. Issue #163 is not complete.

### Working-version preview

The development draft editor displays the native Markdown textarea and a read-only working-version preview in two columns. At narrow widths the preview is hidden off the right edge until the pull tab opens it. The title and future publication action remain on one compact row; the preview has no route, editable surface, Universe or visual diff.

The preview reuses `PublicArticlePresentation`, the public article class contract and the production presentation CSS. The existing React reading view also uses the shared title/cover header. The static publisher remains Ruby-owned and emits the same public classes; the preview does not introduce a second article stylesheet or a public draft document. The browser-side Markdown extensions render the current local Y.Text directly, so text, tables and highlighted code continue to update without the API. Media uses the existing URL and embed rules; an offline message distinguishes unavailable images and embeds from the still-available text preview. Preview links open their published destinations in a separate tab.

The browser integration covers the public title and automatic cover placement, table and Ruby syntax rendering, side-by-side and sliding layouts, separate link navigation and offline text updates at wide and narrow viewport sizes.

### Horizontal inbox

The draft editor connects the existing inbox beneath the editor and preview as four horizontally arranged columns for photos, videos, Raindrop bookmarks and Bluesky posts. Each column scrolls vertically on its own; narrow screens retain access to every column through horizontal scrolling. Photo and video cards show only their media, with no title, timestamp or separate insertion control. Selecting any card inserts its Markdown at the textarea selection.

Photo insertion uses the existing public-media adoption endpoint and changes the draft only after adoption succeeds. Video and external links reuse their existing public URLs. Insertions are local Yjs edits with an isolated Undo boundary. An invalid asset, failed adoption or offline selection leaves the Markdown unchanged; no offline upload queue or full-inbox cache is introduced. Refreshing photo and video columns reloads existing inbox data, while Raindrop and Bluesky columns run their existing source-specific synchronization before reloading.

This slice does not create draft-private assets, promote media at publication, delete unused assets or remove items from the inbox. Those existing public-media retention semantics remain unchanged. Browser coverage exercises caret insertion and Undo through the real textarea and Yjs session, successful and failed photo adoption, source synchronization, independent column scrolling and narrow-screen horizontal access. API responses are replaced only at the external service boundary.

### Remaining manual input verification

Use two tabs of the development editor with a disposable draft. With the real Japanese IME, leave a phrase uncommitted in one tab while appending text in the other. Confirm the composition is not replaced, commit it, and check that both edits remain with the caret in a usable position. Repeat using browser-menu Undo/Redo and the mobile editing menu; Undo must remove only that tab's edit. Record OS, browser, input method, result and any untested environment. Synthetic composition and keyboard automation do not substitute for these checks.

### Checkpoint reconstruction core

The initial part of [checkpoint compaction](https://github.com/asonas/weblog.ason.as/issues/164) is in `lambda/draft_worker/reconstruct.ts`. It reconstructs an exact sequence range from a prior checkpoint and complete decoded logical updates. The caller must supply one article's trusted persisted records; this function is not a public request handler. Payload digests, sequence continuity, protocol/generation, unresolved Yjs dependencies, plain-text shape, the 512 KiB UTF-8 body limit, 2 MiB updates and 16 MiB checkpoints are checked before returning a candidate.

Candidate verification checks coverage of both structures and deletion ranges, then reconstructs the candidate in a second document. It preserves CRDT identity instead of replacing the document with Markdown. Tests cover deletion-only updates whose state vector is unchanged, an old offline client's changes after checkpoint creation, later suffix updates, and corrupt/missing/incompatible input. The pinned Yjs version's unresolved-state fields are inspected because applying an update alone does not prove its dependencies were available. The update APIs are described in the [Yjs documentation](https://docs.yjs.dev/api/document-updates).

Run `mise exec -- npm run test:draft-worker`, `mise exec -- npm run typecheck:draft-worker` and `mise exec -- npm run lint:draft-worker`.

The reconstruction core has no database, AWS or publishing side effects. `markdownDigest` hashes only the body, not the complete publication content including metadata.

### Internal checkpoint persistence

`DraftStore#checkpoint_job` captures the article's fixed head and active checkpoint in one transaction. The existing paginated update reader can supply the suffix through that head. `activate_verified_checkpoint` is an internal-only storage boundary for trusted worker results, not a verification service or a browser endpoint. It checks article identity, protocol/generation, sequence, digest and size, then stages immutable chunks in separate commits. It verifies the complete stored payload before atomically writing the manifest and compare-and-swap active pointer in a small transaction. Interrupted staging is invisible to checkpoint readers and can resume with identical bytes; different bytes at an existing chunk position conflict. Staged orphan cleanup is not enabled. The expected previous checkpoint prevents stale workers from replacing newer checkpoints. Later document updates and all original receipts/payloads remain intact. Retrying the same active checkpoint preserves its activation timestamp; changing its bytes is rejected.

Focused SQLite integration tests cover chunked storage, suffix and receipt preservation, stale-worker rejection, interrupted staging, activation rollback and rejection of missing chunks. A Ruby-to-JavaScript fixture passes real stored Yjs updates through the reconstruction core, activates the result, then reconstructs from the stored checkpoint. Run `mise exec -- ruby -S bundle exec ruby -Itest test/authoring/test_draft_checkpoints.rb` with Node dependencies installed.

DSQL boundary testing on 2026-09-19 reproduced `transaction size limit 10mb exceeded` for a 16 MiB random binary checkpoint stored as base64 in one transaction (`Current transaction size 21.37mb > 10mb`). A repeating-byte fixture had passed, so it did not establish the operational bound. Per-chunk staging keeps activation below the [documented DSQL write-transaction limit](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/CHAP_quotas.html). These binary fixtures exercise opaque storage, not Yjs semantic verification.

After the staging change, live DSQL verification passed exact storage/reassembly of a random 16 MiB checkpoint, idempotent activation, stale-worker rejection, suffix preservation and original receipt retention, alongside the 2 MiB update checks. The isolated verification schema and all six temporary tables were removed after the run. Existing production article tables were not modified. This establishes the tested storage boundary, not production worker wiring or deployment readiness.

The same isolated DSQL boundary test later passed all 64 ordered 256 KiB transport reads for that random checkpoint, seven-day removal of 17 covered update chunks, idempotent cleanup, receipt retention, HTTP 410 restart signaling and suffix reads. Its temporary schema and six tables were also removed after verification.

The production-shaped Node repository was then verified against a separate temporary DSQL schema. It loaded a 1,300,029-byte deletion-only Yjs update from ten immutable rows, crossed the 1 MiB threshold, reconstructed and CAS-activated its checkpoint, retained the update receipt, and removed both covered payload chunks and an abandoned transport upload after their seven-day windows. The script drops its unique schema in `finally`; both recorded runs completed cleanup. Run it only with an explicitly authorized temporary-schema credential: `DSQL_HOST=... AWS_REGION=ap-northeast-1 npx --yes tsx --no-cache test/fixtures/drafts/verify_dsql_worker.ts`.

### Local compaction orchestration

`DraftStore#compact` captures a fixed head, reads the suffix after the active checkpoint and invokes trusted reconstruction only when that suffix reaches 1,000 updates or 1 MiB of decoded data. It calls the worker outside a database transaction, checks the returned range and activates using the captured previous checkpoint. Covered updates do not count toward the next run. Reconstruction errors leave the active checkpoint and original updates untouched.

For an existing local development SQLite database, run `mise exec -- ruby bin/compact-local-draft data/development/drafts.sqlite3 ARTICLE_ID`. The command uses the real JavaScript reconstruction core in a Node subprocess and reports only the checkpoint sequence, digest and activation time, or a below-threshold result. It does not create a database or tables. Node dependencies must be installed. This local runner buffers the selected history in memory and is not a production Lambda transport; production work must read persisted payloads through a bounded internal path rather than putting the entire history into an invocation payload.

Integration coverage exercises both thresholds, fixed-range activation with a later suffix, deletion preservation, skipping an already compacted history, and a failing Node process that leaves source updates and retry receipts intact.

Authenticated catch-up responses expose an active checkpoint only when it fits within the request's fixed high-water mark. The checkpoint is transported as ordered 256 KiB decoded chunks. The browser keeps its applied cursor unchanged until every chunk has the same manifest, the complete SHA-256 digest matches and Yjs accepts the assembled update; it then continues with suffix updates. An interrupted download starts again without discarding IndexedDB state. API integration covers bounded reassembly followed by a suffix, while frontend tests cover complete, reordered, inconsistent, malformed and corrupt chunk sequences.

`DraftStore#cleanup_compacted` removes only update chunk rows covered by an active checkpoint after its seven-day retention period. Update manifests and receipts remain, so an identical retry still returns its original receipt. Suffix payloads and active checkpoint dependencies remain. Cleanup is restartable and each logical update is deleted separately to keep DSQL transactions bounded. A client whose older fixed high-water range expires receives HTTP 410 and restarts catch-up from the current checkpoint without replacing its local Yjs state.

The internal worker connects directly to DSQL with IAM, enumerates draft IDs, captures each fixed head and active checkpoint, verifies the persisted range with Yjs, stages bounded checkpoint rows and CAS-activates the manifest. One bad article is reported without preventing independent articles from being inspected; the invocation still fails visibly when any article failed. Covered update chunks and abandoned partial uploads are reclaimed after seven days. Old inactive checkpoint staging is retained because deleting it is not required for correctness and no safe age/reference policy is currently needed.

The Lambda container build, ECR repository, runtime role, rollback metadata and deployment workflow are wired, but no resource was applied or image deployed by this implementation. The hourly rule remains disabled until a separately authorized migration and activation. No checkpoint activation route was added to the public API. An untrusted caller must never be allowed to supply results to the internal activation method or compaction block.

Outbound Webmention sending remains intentionally disabled. This work must never enable delivery, drain queues or replay unsent notifications. Production deployment and migration require separate authorization.
