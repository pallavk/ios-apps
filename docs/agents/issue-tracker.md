# Issue tracker: GitHub

Issues and specs for this repository live as GitHub issues in `pallavk/ios-apps`. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`.
- **Read an issue**: `gh issue view <number> --comments`, including labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments` with appropriate label and state filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`.
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`.
- **Close an issue**: `gh issue close <number> --comment "..."`.

Infer the repository from `git remote -v`; `gh` does this automatically when run inside this clone.

## Pull requests as a triage surface

**PRs as a request surface: no.** Set this to `yes` only if this repository later treats external pull requests as feature requests.

GitHub shares one number space across issues and pull requests. Resolve an ambiguous `#42` with `gh pr view 42`, then fall back to `gh issue view 42`.

## Skill operations

- When a skill says **publish to the issue tracker**, create a GitHub issue.
- When a skill says **fetch the relevant ticket**, run `gh issue view <number> --comments`.
- Prefix app-specific issue titles with the app name when useful, such as `[Pocket Tray]`.

## Wayfinding operations

The `wayfinder` map is a single issue with child issues as tickets.

- Label maps `wayfinder:map`.
- Link child tickets as GitHub sub-issues when available; otherwise use a task list in the map and add `Part of #<map>` to each child.
- Label children `wayfinder:<type>`, where type is `research`, `prototype`, `grilling`, or `task`.
- Represent blocking with GitHub issue dependencies when available; otherwise add `Blocked by: #<n>` to the child.
- Claim a ticket with `gh issue edit <n> --add-assignee @me`.
- Resolve a ticket by commenting with the answer, closing it, and updating the map's decisions.
