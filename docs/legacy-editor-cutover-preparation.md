# Legacy editor cutover preparation

This is the preparation for #171, not permission to deploy, migrate, reject production writes or enable draft routes. The legacy backend continues accepting its existing save/rename protocol. Outbound Webmention remains disabled.

## Rejection contract for the migration step

The cutover implementation in #172 must reject legacy mutations before modifying article or publication state. Use JSON with a machine-readable `code` and a human-readable `error`, served with `Cache-Control: no-store`:

| Condition | Status | JSON code | Prepared editor behavior |
| --- | --- | --- | --- |
| Legacy protocol is obsolete | 409 | `upgrade_required` | Stop this tab's save/rename attempts; retain edits and offer Markdown download and a separately opened tab |
| Authoring maintenance window | 503 | `authoring_maintenance` | Stop automatic writes; retain edits and offer download and explicit save retry |
| Transient failure, including non-JSON 502 | Existing status | No cutover code | Retain edits and existing retry-on-edit/blur behavior; do not mislabel as maintenance or an upgrade |

The prepared client recognizes these codes on failed POST/PATCH `/api/authoring/pages` requests and POST `/api/rename`. It cancels queued autosaves when a recognized rejection arrives and does not reload, redirect, replace text or treat the rejection as a successful save. Text remains editable. Download reads the latest title and Markdown body, including edits made after the rejected request. The first heading contains the title; the body follows unchanged. The file is a recovery copy, not a server-save acknowledgment. Cover settings and other metadata are not imported by this export; record them separately when preserving a tab.

An explicit maintenance retry uses the current text and, when necessary, the existing rename-confirmation path. An obsolete tab has no retry action: after verifying the downloaded copy, open a new tab manually. Keep the old tab until the new editor's content has been checked and saved. No whole-body-to-CRDT bridge or dual-writer window is provided.

## Delivery order and pre-cutover gate

1. Obtain separate approval to deploy this frontend protection while the old save/rename backend remains active. Record the deployed build SHA and confirm that a newly opened editor uses that build. Do not deploy the cutover rejection in this first step. Test the rejection in an isolated browser/API fixture, not against a real article's production write path.
2. Before migration, inventory every editing tab and window on each browser/device, including suspended or offline sessions. A deployment cannot update JavaScript already loaded in an old tab. Tabs opened before this protection may show only a generic error and have no download action; do not assume they are protected because a new tab is.
3. For each older tab, preserve unsaved title and body manually in a local text/Markdown file **before** closing or reloading. Record its article URL and any changed cover/type metadata. If raw Markdown is unavailable in that old UI, copy its selected text into a local file and separately record links, image/video URLs, code and other formatting; visually compare against the tab. Do not reload merely to obtain the new export button. Keep the tab open if a complete recovery copy cannot be verified.
4. Verify each recovery copy actually opens and includes the latest edits, not just the last server version. After preservation, allow any still-valid legacy saves to finish and compare their server state. Close or deliberately retain inventoried tabs with a known recovery copy. Any unaccounted device/session, uncertain save or unverified copy blocks the cutover; inventory again on reconnect.
5. Only after separately authorized deployment of the protection and completion of that inventory may a separately authorized #172 maintenance/migration proceed: stop writers, settle in-flight writes and legacy publication, preserve source data, pause old generators, migrate/verify, then reopen new editing. Reader access continues. This document does not execute those steps or authorize sending Webmentions.

Deploying this preparation is not evidence that pre-existing tabs can understand the new rejection. Do not force reload them, silently discard their content, or roll a legacy writer back over new CRDT state after new editing has reopened. Follow the parent specification's maintenance and rollback boundaries.

## Verification

Run `MISE_ACTIVATE_AGGRESSIVE=true mise exec -- node --import tsx --test --test-name-pattern='legacy .* requires|distinguishes transient failure' frontend/authoring/editor.test.ts` for save/rename rejection, latest-text export, automatic-write suppression, unload warning, maintenance retry and ordinary transient failure through the existing HTTP boundary.

Run `MISE_ACTIVATE_AGGRESSIVE=true mise exec -- node test/browser/legacy_editor_cutover.mjs` with Chrome and permission to bind loopback port 15184. It starts an isolated Vite server and substitutes only API responses. It verifies actual typing, download contents, absence of navigation/reload and a narrow screen. It does not contact production or enable new production routes.
