# Draft authoring development

This is the first implementation slice of [the draft authoring specification](https://github.com/asonas/weblog.ason.as/issues/161), tracked in [Create, save and resume drafts](https://github.com/asonas/weblog.ason.as/issues/162). It does not replace the legacy editor or enable production draft writes.

## Local use

Run the backend with `AUTHORING_DRAFTS_ENABLED=1 mise exec -- ruby -S bundle exec ruby bin/authoring`, then the frontend with `mise exec -- npm run dev`. Open `/draft-editor`. Its URL receives a stable draft ID; keep that URL to reopen the draft until the administration list is implemented.

The development backend stores drafts separately in `data/development/drafts.sqlite3`. It inherits the existing loopback-only development authentication configuration. When GitHub authentication is configured, draft reads require login and writes also require CSRF verification. Without OAuth configuration, only the explicitly enabled loopback development instance allows unauthenticated access. The Lambda API requires authentication for all draft operations and defaults to disabled unless a store is injected. No production handler, route, infrastructure or sender configuration is enabled here.

Native Markdown input and metadata are persisted in IndexedDB; a separate message reports durable server acknowledgment. Do not interpret a server receipt as semantic validation of Yjs. Ruby verifies the transport digest and declared body size but stores opaque updates. The browser enforces the 512 KiB Markdown bound without truncation. Trusted reconstruction and authoritative publication validation belong to the subsequent publication/compaction slices.

Updates use stable IDs and digests, atomic head/receipt/payload commits and bounded fixed-high-water catch-up. Complete logical updates are split into storage rows inside one transaction. Staged multi-request uploads and checkpoint cleanup belong to the compaction slice. The PostgreSQL adapter accepts an Aurora DSQL pool with OCC retries, but schema provisioning and production wiring are deliberately absent. SQLite tests do not establish live DSQL compatibility.

## Verification

- API integration: `mise exec -- ruby -S bundle exec ruby -Itest test/authoring/test_drafts.rb`
- Browser integration: `mise exec -- node test/browser/draft_editor.mjs`
- Type checks: `mise exec -- npm run typecheck` and `mise exec -- ruby -S bundle exec steep check`

The browser test requires installed Chrome and permission to bind loopback ports 18082 and 15182. It starts an isolated temporary SQLite backend and Vite, verifies IndexedDB and fresh-browser recovery, selective local Undo/Redo, delayed acknowledgment with intervening edits, oversized-input retention and public-data isolation, then stops its child servers. It does not contact AWS or use the author's real draft database.

## Delivery boundaries

The first part of [offline recovery and conflict merging](https://github.com/asonas/weblog.ason.as/issues/163) adds automatic retries for network failures and HTTP 408/429/5xx, retaining the persisted update ID after a lost response. Requests time out after 15 seconds. Authentication, validation and conflict errors pause background retries; the explicit retry button remains available. Visible editors check for server changes every 10 seconds and on focus/reconnection. Sending starts after 1 second idle or 5 seconds of continuous input, subject to an already-running request or composition.

Incoming body updates are deferred during composition. Browser coverage exercises API-disconnected reload from IndexedDB, reconnect, lost-response retry, a non-JSON 502, authentication failure, remote refresh, continuous input, synthetic composition and local-only Undo. API-disconnected reload assumes that the application shell remains available; offline asset caching is not implemented. Synthetic composition events do not establish real Japanese IME or mobile menu behavior.

Metadata changes to independent fields merge automatically. Concurrent changes to the same field retain the local value and the current server revision, and offer an explicit local/server choice. Conflicts survive reload. A confirmed metadata rejection clears the rejected flight while retaining its unsent body updates, then fetches the current server state before asking for a choice. An ambiguous network failure never clears that flight. Browser coverage includes offline title conflicts across separate browser contexts, reload, keyboard selection, a metadata race after sending starts, and independent title/type changes.

Same-browser tabs merge each IndexedDB write with the current stored record in one read/write transaction. Body state is merged with Yjs; pending updates are changed relative to the writer's previous snapshot, so a stale tab cannot remove another tab's work or revive acknowledged updates. BroadcastChannel notifies other tabs to reload the durable state; notifications are deferred during composition. Web Locks serialize server synchronization for each draft, including catch-up on opening. Closing a sender leaves the persisted flight available for another tab to retry with the same ID. Concurrent local metadata candidates are retained for explicit selection, including candidates not yet seen by a tab resolving an older conflict.

Browser verification covers two tabs editing while the API is disconnected, immediate propagation, local-only Undo/Redo, reload of both tabs, local metadata conflicts and a sender closing after losing its response. A fresh browser context verifies the resulting server body. These paths require Web Locks and BroadcastChannel; there is no unsafe unlocked fallback.

The browser test injects `QuotaExceededError` at the IndexedDB write boundary. It verifies that text remains editable, the storage warning appears, Markdown download preserves the exact body, and no update is sent before durable local storage succeeds. After storage recovers, retry persists the failed changes before synchronization; reload and a fresh browser context both recover the body. This simulates the storage error rather than filling the user's disk.

Real Japanese IME/mobile menu Undo validation, corruption recovery, compaction and publication remain unfinished. No public preview, inbox or administration UI is implemented here. Issue #163 is not complete.

### Remaining manual input verification

Use two tabs of the development editor with a disposable draft. With the real Japanese IME, leave a phrase uncommitted in one tab while appending text in the other. Confirm the composition is not replaced, commit it, and check that both edits remain with the caret in a usable position. Repeat using browser-menu Undo/Redo and the mobile editing menu; Undo must remove only that tab's edit. Record OS, browser, input method, result and any untested environment. Synthetic composition and keyboard automation do not substitute for these checks.

### Checkpoint reconstruction core

The initial part of [checkpoint compaction](https://github.com/asonas/weblog.ason.as/issues/164) is in `lambda/draft_worker/reconstruct.ts`. It reconstructs an exact sequence range from a prior checkpoint and complete decoded logical updates. The caller must supply one article's trusted persisted records; this function is not a public request handler. Payload digests, sequence continuity, protocol/generation, unresolved Yjs dependencies, plain-text shape, the 512 KiB UTF-8 body limit, 2 MiB updates and 16 MiB checkpoints are checked before returning a candidate.

Candidate verification checks coverage of both structures and deletion ranges, then reconstructs the candidate in a second document. It preserves CRDT identity instead of replacing the document with Markdown. Tests cover deletion-only updates whose state vector is unchanged, an old offline client's changes after checkpoint creation, later suffix updates, and corrupt/missing/incompatible input. The pinned Yjs version's unresolved-state fields are inspected because applying an update alone does not prove its dependencies were available. The update APIs are described in the [Yjs documentation](https://docs.yjs.dev/api/document-updates).

Run `mise exec -- npm run test:draft-worker`, `mise exec -- npm run typecheck:draft-worker` and `mise exec -- npm run lint:draft-worker`.

The reconstruction core has no database, AWS or publishing side effects. `markdownDigest` hashes only the body, not the complete publication content including metadata.

### Internal checkpoint persistence

`DraftStore#checkpoint_job` captures the article's fixed head and active checkpoint in one transaction. The existing paginated update reader can supply the suffix through that head. `activate_verified_checkpoint` is an internal-only storage boundary for trusted worker results, not a verification service or a browser endpoint. It checks article identity, protocol/generation, sequence, digest and size, then atomically writes all checkpoint chunks, the manifest and a compare-and-swap active pointer. The expected previous checkpoint prevents stale workers from replacing newer checkpoints. Later document updates and all original receipts/payloads remain intact. Retrying the same active checkpoint preserves its activation timestamp; changing its bytes is rejected.

Focused SQLite integration tests cover chunked storage, suffix and receipt preservation, stale-worker rejection, transaction rollback on write failure and rejection of missing chunks. A Ruby-to-JavaScript fixture passes real stored Yjs updates through the reconstruction core, activates the result, then reconstructs from the stored checkpoint. Run `mise exec -- ruby -S bundle exec ruby -Itest test/authoring/test_draft_checkpoints.rb` with Node dependencies installed. This is local integration evidence, not DSQL transaction/limit verification.

Production worker invocation/authentication, transport chunk manifests, compaction scheduling, client checkpoint catch-up and seven-day payload cleanup are not wired yet. The new checkpoint tables are created only where draft-store setup is explicitly run; no production schema was provisioned. No checkpoint reader or activation route was added to the public API. An untrusted caller must never be allowed to supply results to the internal activation method. Issue #164 remains incomplete.

Outbound Webmention sending remains intentionally disabled. This work must never enable delivery, drain queues or replay unsent notifications. Production deployment and migration require separate authorization.
