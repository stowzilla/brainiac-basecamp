# Changelog

All notable changes to brainiac-basecamp will be documented in this file.

## [0.0.17] - 2026-08-24

### Added

- `brainiac basecamp reset task <card> [--to <status>]` — manually reset a task's status
- `brainiac basecamp reset gates <card>` — clear gate approvals and re-dispatch on next cycle
- `brainiac basecamp reset epic <todolist-id> [--to <status>] [--reactivate]` — reset all tasks or reactivate a completed epic
- `brainiac basecamp epics` now shows todolist IDs in output
- `brainiac basecamp epics --verbose` shows per-task status breakdown

## [0.0.7] - 2026-08-24

### Fixed

- Review gates are now re-dispatched on restart when no gate responses have been received. Previously, if a GitHub webhook was missed (or gate agents crashed), tasks would stay in `in_review` indefinitely with "0 approvals, waiting for more reviews." Now both the startup resume and the 90-second health monitor will re-dispatch gates if `gates_dispatched_at` is nil or more than 5 minutes have passed with no responses.

## [0.0.5] - 2026-08-21

### Fixed

- Epic task dispatch now uses project-specific agents instead of always using the epic's agent. Tasks tagged for projects with their own `agent_name` in `projects.json` will now route to the correct agent. For example, droidzilla cards will now dispatch to Sheogorath instead of Galen when part of a multi-project epic.

## [0.0.4] - 2026-08-21

- Initial versioned release
- Epic orchestration with dependency tracking
- Review gates (GLaDOS, Threepio) with parallel dispatch
- Epic branch mode with final PR workflow
- Self-healing on restart
- Discord notifications
