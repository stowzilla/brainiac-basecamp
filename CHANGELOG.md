# Changelog

All notable changes to brainiac-basecamp will be documented in this file.

## [0.0.27] - 2026-09-03

### Added

- **CLI commands for ephemeral Belt environment config.** Two new `set` keys let operators configure per-card ephemeral Belt deploys:
  - `brainiac basecamp set ephemeral-deploys <on|off>` — toggles auto-creation of ephemeral Belt environments for Fizzy cards tagged `deploy` (stored at `deploy.ephemeral_enabled`).
  - `brainiac basecamp set parent-env <project> <env>` — sets the parent environment a card's ephemeral env is cloned from (stored under `deploy.project_envs.<project>`).

  When a `deploy`-tagged card is assigned on a Belt app, the workflow creates `belt g environment fizzy-<card> <parent-env>`, deploys to it, redeploys on PR push, and destroys it on PR merge. Help output now documents the full flow. The `set` command was also hardened so each key validates its own required arguments instead of failing on a shared `key && value` guard.

## [0.0.26] - 2026-09-03

### Fixed

- **`reset task <card> --to complete` now finalizes the epic when it's the last straggler.** Previously the task went complete but the epic stayed `status="active"`, and the completed task kept `awaiting_final_decision=true`. That left the epic in the "all tasks done but still active" state the 90s reconcile loop re-detects on every sweep — re-running `complete_epic` and re-posting the "🎉 Epic completed" notification (the belt-organizations spam loop). Operators had to hand-edit `basecamp_epics.json` to seal it. Both `reset task` and `reset epic` now seal the epic in the same atomic write (`status=complete`, `completed_at`, `completion_notified=true`) and clear `awaiting_final_decision` on the completed task, via a shared `finalize_epic_if_all_complete!` helper.

## [0.0.25] - 2026-09-02

### Fixed

- **Dispatch prompts no longer built with a blank `PR #`.** When a task was re-dispatched but had no PR number, the "changes requested on PR #N" template rendered as "...fixes on PR #" with a hole in it, and the agent couldn't proceed. Dispatch now uses a clean "start implementation" prompt when there's no PR and only the "changes requested on PR #N" prompt when a real PR exists. (#34)
- **Epic-review no longer claims unverified completions.** `dispatch_epic_review` posted "Card #N just completed" to Basecamp based solely on a ledger flag, with no proof any work shipped. It now checks `card_completion_verified?` (a real tracked PR) before posting the checkpoint; with no PR evidence it skips the claim but still runs the callback so the resolver advances. (#34)

## [0.1.0] - 2026-08-24

### Added

- **SessionRegistry module** — first-class agent session liveness tracking via PID checks. Replaces the old pattern of inferring agent liveness from elapsed time or Fizzy assignment state.
  - `SessionRegistry.register_session(task_id, pid)` — track active agent sessions
  - `SessionRegistry.alive?(task_id)` — direct PID liveness check
  - `SessionRegistry.mark_dead(task_id)` — explicit session termination
  - `SessionRegistry.sessions_for_epic(epic_id)` — list sessions by epic
  - `SessionRegistry.any_alive_for_card?(card_number)` — check if any agent is running for a card
  - `SessionRegistry.reap_dead!` — periodic sweep for crashed agents
  - `SessionRegistry.clear_all!` — called on server restart (all PIDs assumed stale)
- Sessions persisted to `~/.brainiac/basecamp_sessions.json` for crash recovery diagnostics
- Session status exposed via `/api/basecamp` endpoint
- Health monitor now reaps dead sessions and sweeps old entries each cycle

### Changed

- Health monitor `in_flight` check uses `SessionRegistry.alive?` instead of elapsed-time heuristic
- Gate agent dispatch (`ReviewGate.dispatch_agent_for_review`) registers sessions via `SessionRegistry`
- Final decision dispatch (`Hooks.dispatch_final_decision`) registers sessions via `SessionRegistry`
- Epic review dispatch (`Orchestrator.dispatch_epic_review`) registers sessions via `SessionRegistry`
- All above replace the fragile `Object.send(:register_session, ...)` pattern with the new module

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
