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

Real Japanese IME/mobile menu Undo validation, local-storage failure UX verification, corruption recovery, compaction and publication remain unfinished. No public preview, inbox or administration UI is implemented here. Issue #163 is not complete.

Outbound Webmention sending remains intentionally disabled. This work must never enable delivery, drain queues or replay unsent notifications. Production deployment and migration require separate authorization.
