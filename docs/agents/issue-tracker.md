# Issue tracker: Linear

Issues and specs for this repo live in Linear. Use the available Linear tools for issue operations.

## Scope

- Team: `Asonas` (`ASO`), UUID `5b63ab0c-c50e-4d8a-b895-1ddc27fe09b4`.
- Project: `weblog.ason.as` (`P-ASO-2`), UUID `69e305ea-0813-4994-8706-9b911c9c103e`.
- Project URL: https://linear.app/asonas/project/weblogasonas-bb74606ef8b6
- GitHub repository: `asonas/weblog.ason.as`. Use `gh` for repository and pull request operations.

Always specify this team and project when creating or listing issues. Before editing a ticket, verify that it belongs to this project. Use Linear identifiers such as `ASO-123` or full URLs; legacy GitHub `#123` references remain GitHub references.

## Conventions

- Create: `save_issue` with `team`, `project`, `title`, and Markdown `description`. Apply triage labels according to `docs/agents/triage-labels.md`.
- Read: `get_issue` with `includeRelations: true`, plus `list_comments` for discussion. Follow pagination when present.
- List: `list_issues` scoped to the team and project, with the appropriate label and state filters. Follow pagination when present.
- Update: `save_issue` with the existing issue ID. Use `addLabels` and `removeLabels` to preserve unrelated labels.
- Comment: `save_comment` with `issueId` and Markdown `body` when the task authorizes a comment.
- Complete implemented or answered work: set `state` to `Done`.
- Decline work: apply `wontfix` and set `state` to `Canceled`.
- Duplicate: set `duplicateOf` to the canonical Linear issue and use the team's `Duplicate` state.
- Check `list_issue_statuses` before changing state if the team's workflow has changed. Triage labels describe readiness; they are separate from workflow states.

## When a skill says "publish to the issue tracker"

Create a Linear issue in this team and project.

## When a skill says "fetch the relevant ticket"

Read the Linear issue, its relations, and its comments.

## Pull requests as a triage surface

**PRs as a request surface: no.**

## Wayfinding operations

Used by `/wayfinder`. The map is a Linear issue within this project, with child issues as tickets.

- Map: an issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body.
- Child ticket: create an issue in the same team and project with `parentId` set to the map issue. Use `wayfinder:<type>` labels (`research`, `prototype`, `grilling`, or `task`). Create missing labels only when needed by this workflow.
- Blocking: use native `blockedBy` / `blocks` relations. Read relations with `get_issue`; do not replace dependencies with prose alone.
- Frontier: list the map's children with `parentId`, following pagination. Exclude terminal or assigned tickets and tickets with unresolved blockers. Follow the ticket order recorded in the map; if absent, use creation order. A canceled or duplicate blocker is not evidence of completed work: inspect its resolution and canonical issue before proceeding.
- Claim: assign the child ticket to `me` as the session's first write.
- Resolve: record the answer in an authorized issue comment, mark the ticket `Done`, and append a context pointer to the map's Decisions-so-far.

## Existing GitHub issues

This setup changes the destination for future issue work. Existing GitHub issues remain available as historical references until explicitly migrated. Migration must preserve source URLs and avoid duplicate Linear issues; closing source issues is a separate operation.
