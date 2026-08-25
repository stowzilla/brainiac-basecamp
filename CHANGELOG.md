# Changelog

All notable changes to brainiac-basecamp will be documented in this file.

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
