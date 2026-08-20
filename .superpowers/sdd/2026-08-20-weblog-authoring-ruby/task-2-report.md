# Task 2 Report

Date: 2026-08-20
Branch: `weblog-authoring-design`
Implementation Commit SHA: `cff5fb2`
Implementation Commit Subject: `Add Ruby content repository and index`

## Files

- `lib/weblog_authoring.rb`
- `lib/weblog_authoring/models.rb`
- `lib/weblog_authoring/frontmatter.rb`
- `lib/weblog_authoring/database.rb`
- `lib/weblog_authoring/repository.rb`
- `test/authoring/test_repository.rb`
- `test/authoring/test_database.rb`

Python authoring implementation and design/spec files were not modified or deleted.

## Implemented

- Added `ContentRepository` with:
  - `refresh`
  - `get_page`
  - `find_route`
  - `list_pages`
  - `save_draft`
  - `rename_named_page`
- Added `RepositorySnapshot` carrying valid `pages`, `problems`, and `redirects`.
- Added `FileTransaction` using temporary files, `fsync`, and `File.rename`, with rollback on failure.
- Added `AuthoringDatabase` with:
  - `rebuild`
  - `backlinks`
  - `search`
  - `integrity_ok?`
- Added `ConflictError`.
- Ensured frontmatter serialization avoids YAML alias emission for duplicated `Time` objects.

## Requirement Check

- File save rollback:
  - Covered by `test_save_draft_restores_created_files_when_transaction_fails`
- File rename rollback:
  - Covered by `test_rename_restores_source_files_when_transaction_fails`
- SQLite missing rebuild:
  - Covered by `test_rebuild_restores_index_after_database_file_is_deleted`
- SQLite corrupt rebuild with `.corrupt-*` backup:
  - Covered by `test_corrupt_database_is_rotated_and_rebuilt`
- Schema migration / compatibility failure backup and rebuild:
  - Covered by `test_schema_version_mismatch_is_rotated_and_rebuilt`
- SQLite does not store body text:
  - Covered by `test_rebuild_stores_problems_but_not_document_bodies`
- Links / backlinks / search:
  - Covered by `test_backlinks_can_exclude_draft_sources_and_search_filters_status`
- Rename collision:
  - Covered by `test_rename_collision_leaves_all_source_files_unchanged`
- Empty draft creation from `[[page-a]]`:
  - Covered by `test_saving_wiki_link_creates_an_empty_named_draft`
- Duplicate date save rejection:
  - Covered by `test_second_date_page_for_same_day_is_rejected`
- External markdown remains source of truth after edits:
  - Covered by `test_refresh_uses_external_markdown_edits_as_source_of_truth`
- Broken external documents stay out of valid pages and are not overwritten:
  - Covered by `test_invalid_external_document_is_reported_without_overwrite`

## Commands And Results

1. `command -v ruby`
   - Result: `/usr/bin/ruby`
2. `mise exec -- ruby --version`
   - Result: `ruby 3.3.6 (2024-11-05 revision 75015d4c1f) [arm64-darwin23]`
   - Note: `mise` emitted cache/tracking warnings due sandboxed state paths, but executed Ruby 3.3.6 successfully.
3. `mise exec -- ruby -c lib/weblog_authoring.rb lib/weblog_authoring/models.rb lib/weblog_authoring/frontmatter.rb lib/weblog_authoring/database.rb lib/weblog_authoring/repository.rb test/authoring/test_repository.rb test/authoring/test_database.rb`
   - Result: `Syntax OK`
4. `mise exec -- ruby -Itest test/authoring/test_repository.rb test/authoring/test_database.rb`
   - Result: `11 runs, 40 assertions, 0 failures, 0 errors, 0 skips`
5. `git --no-pager diff --check`
   - Result: no whitespace / patch format issues
6. `git commit -m "Add Ruby content repository and index"`
   - Result: committed on `weblog-authoring-design` as `cff5fb2`

## Concerns

- `AuthoringDatabase#search` indexes and queries route metadata only, not body text. This matches the current Task 2 scope and management-page search needs, but full-text search would require a later task.
- `mise` warnings about tracked-config/cache writes were environmental and did not block syntax checks or tests.

## Fix Round 1

Date: 2026-08-20
Branch: `weblog-authoring-design`

### Changed Files

- `lib/weblog_authoring/names.rb`
- `lib/weblog_authoring/database.rb`
- `test/authoring/test_names.rb`
- `test/authoring/test_repository.rb`
- `test/authoring/test_database.rb`

### Addressed Findings

- Named page source filenames are now deterministic and case-distinguishing on macOS case-insensitive filesystems.
  - Lowercase ASCII remains readable, for example `page-a.md`.
  - Uppercase ASCII bytes are percent-encoded in filenames, for example `Page-A` becomes `%50age-%41.md`.
  - Public routes and page names remain case-sensitive and unchanged, so `/page-a` and `/Page-A` can coexist.
  - Save, rename, and external canonical path validation all use the same filename rule.
- `AuthoringDatabase#schema_compatible?` now validates expected column structure for `pages`, `links`, and `problems`, not just table names and `user_version`.
  - Incompatible derived DBs are rotated to `.corrupt-*` and rebuilt from Markdown.
  - Source Markdown is not modified during this recovery.
- Added concrete tests for `RepositorySnapshot#with_redirect`.
  - `with_redirect` preserves valid pages and problems.
  - It returns a new immutable snapshot and does not duplicate identical redirects.
  - Redirect manifest persistence remains intentionally out of scope for Task 2.

### Commands And Results

1. `mise exec -- ruby -c lib/weblog_authoring/names.rb lib/weblog_authoring/repository.rb lib/weblog_authoring/database.rb test/authoring/test_names.rb test/authoring/test_repository.rb test/authoring/test_database.rb`
   - Result: `Syntax OK`
2. `mise exec -- ruby -Itest -e "require './test/authoring/test_names'; require './test/authoring/test_repository'; require './test/authoring/test_database'"`
   - Result: `29 runs, 102 assertions, 0 failures, 0 errors, 0 skips`
3. `git --no-pager diff --check`
   - Result: no whitespace / patch format issues

### Notes

- The earlier shorthand `ruby test1 test2 ...` form only executes the first Ruby file. Focused tests were rerun with explicit `require` calls so all targeted test files were executed in one process.
