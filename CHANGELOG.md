# Changelog

All notable changes to brainiac-basecamp will be documented in this file.

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
