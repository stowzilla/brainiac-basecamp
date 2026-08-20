---
name: brainiac-plugin-development
description: |
  How to develop Brainiac plugins. Covers the plugin contract, file structure,
  hooks, CLI commands, and architecture constraints.
triggers:
  - plugin contract
  - plugin development
  - register app
  - brainiac hooks
---

# Brainiac Plugin Development

This is a Brainiac plugin gem. Plugins extend Brainiac with new communication
channels, integrations, or features without modifying core.

## Plugin Contract

A valid Brainiac plugin MUST:

1. **Gem named `brainiac-<name>`**
2. **Entry file at `lib/brainiac_<name>.rb`** — loaded by RubyGems
3. **Module at `Brainiac::Plugins::<Name>`** — PascalCase
4. **Implement `.register(app)`** — receives Sinatra::Application at server startup

Optional but recommended:

| Method | File | Purpose |
|--------|------|---------|
| `.register(app)` | main module | **Required.** Define routes, hooks, threads |
| `.configured?` | `metadata.rb` | Returns false → auto-runs setup on install |
| `.help_text` | `metadata.rb` | One-liner for `brainiac help` |
| `.cli(args)` | `cli.rb` | CLI subcommands via `brainiac <plugin> ...` |

## Critical Architecture: CLI vs Server Runtime

Plugins are loaded in TWO contexts:

1. **Server context** — full plugin via `.register(app)`. Has `LOG`, `AGENT_REGISTRY`, etc.
2. **CLI context** — only `metadata.rb` + `cli.rb`. NO server runtime.

Rules:
- `metadata.rb` requires only `version.rb`
- `cli.rb` uses only stdlib (`json`, `net/http`, `fileutils`)
- Everything else loaded only by `.register(app)`

## Available Hooks

Subscribe in `.register(app)` via `Brainiac.on(:event)`:

| Hook | When |
|------|------|
| `:server_started` | All plugins loaded |
| `:pre_dispatch` | Before agent CLI spawned |
| `:agent_completed` | Agent session finished |
| `:agent_crashed` | Agent process crashed |
| `:build_brain_context` | Building prompt context |
| `:pr_merged` | GitHub PR merged |
| `:pr_review_received` | PR review submitted |
| `:pr_synchronized` | PR updated |
| `:production_deployed` | Deploy succeeded |
| `:create_work_item` | Create card/issue/ticket |
| `:detect_cli_provider` | Detect CLI provider |
| `:detect_effort` | Detect effort level |

## Channel Prompts

For communication channel plugins:

```ruby
Brainiac.register_channel_prompt(:my_channel, PROMPT_TEXT, pre_post_check: CHECK_TEXT)
```

## Core Functions (Server Context)

| Function | Purpose |
|----------|---------|
| `agent_display_name(key)` | Display name for agent |
| `agent_env_for(name)` | Env vars hash for agent |
| `AGENT_REGISTRY` | All agents |
| `PROJECTS` | All projects |
| `LOG` | Logger |
| `BRAINIAC_DIR` | ~/.brainiac/ path |
| `register_session(key, pid, **)` | Track active session |
| `session_active?(key)` | Check if session running |
| `build_brain_context(...)` | Build brain context |
| `render_prompt(template, vars, ...)` | Compose full prompt |
| `detect_model(config, text:)` | Detect model from tags |
| `parse_inline_tags(text)` | Parse inline tags |
| `reload_projects!` | Reload projects.json |
| `brain_push(message:)` | Push brain to git |

## Testing

```bash
rake test       # Minitest
rake rubocop    # Linter
rake            # Both
```

## Reference Implementations

- `brainiac-discord` — Communication channel (gateway, messages, delivery, reactions)
- `brainiac-fizzy` — Card management (webhooks, hooks, duplicate detection, planning)
