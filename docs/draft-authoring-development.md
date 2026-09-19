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

Two-tab IndexedDB coordination, automatic retry/polling, full offline conflict UX, real Japanese IME/mobile menu Undo validation, corruption recovery, compaction and publication are later slices. Do not use this initial development editor concurrently in multiple tabs against one draft. No public preview, inbox or administration UI is implemented here.

Outbound Webmention sending remains intentionally disabled. This work must never enable delivery, drain queues or replay unsent notifications. Production deployment and migration require separate authorization.
