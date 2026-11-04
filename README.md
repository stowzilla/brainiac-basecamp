# brainiac-basecamp

Basecamp epic orchestration plugin for [Brainiac](https://github.com/stowzilla/brainiac). Manages high-level epics in Basecamp while agents execute individual tasks via Fizzy cards — with dependency tracking, parallel dispatch, review gates, and bidirectional status sync.

## How It Works

1. Create a Basecamp **todolist** with the `Epic:` prefix
2. Add todos to it — each one references a Fizzy card number in the title
3. Assign any todo in the list to your bot account
4. The plugin receives the webhook, reads the todolist, builds the dependency graph, and starts orchestrating
5. Unblocked Fizzy cards are assigned to agents automatically (in parallel if independent)
6. After each task completes, an epic review agent checks if the plan still makes sense
7. When PRs are opened, review gate agents (GLaDOS, Threepio) review in parallel
8. After all gates approve, the implementation agent makes the final decision and merges
9. When all tasks finish, a final PR is opened from the epic branch to main

## Epic Format

Create a Basecamp todolist with the `Epic:` prefix:

```
Todolist: "Epic: Build Authentication System"

Todos:
  □ #1234 — Set up auth models
  □ #1235 — Add API endpoints [depends:1234]
  □ #1236 — Frontend login form [depends:1234,1235]
```

- **Card reference:** `#1234` in the title links to Fizzy card
- **Dependencies:** `[depends:1234,1235]` in the title declares dependencies
- Cards without dependencies (or with all deps satisfied) dispatch in parallel

## Review Gate Modes

Configure via `brainiac basecamp set review-gate <mode>`:

| Mode | Behavior |
|------|----------|
| `on_complete` | Advance immediately when agent finishes |
| `on_pr_merge` | Wait for PR merge to main before advancing |
| `epic_branch` | PRs target an epic branch; review gates + final decision before merge |

### Epic Branch Mode (Recommended)

The `epic_branch` mode provides the most control:

1. Creates an `epic/<name>` branch when the epic starts
2. All task PRs target the epic branch (not main)
3. After PR opens, **review gate agents** (e.g., GLaDOS, Threepio) review in parallel
4. When all gates approve, the **implementation agent** makes the final decision
5. Agent reviews gate feedback, makes fixes if needed, then merges to epic branch
6. After all tasks complete, a **final PR** opens from epic branch → main

Configure review gates in `~/.brainiac/basecamp.json`:

```json
{
  "review_gate": "epic_branch",
  "review_gates": [
    { "agent": "GLaDOS", "role": "test-engineer" },
    { "agent": "Threepio", "role": "code-reviewer" }
  ]
}
```

## Epic Review Between Tasks

After each task completes (before dispatching the next batch), an **epic review agent** is dispatched to:

1. Read memory files from completed tasks
2. Check if remaining tasks still make sense given implementation decisions
3. Update dependencies if implementation created new relationships
4. Mark tasks obsolete or adjust scope if needed
5. Create new Fizzy cards if gaps are discovered

This prevents wasted work when early implementation decisions change the plan.

## Prerequisites

- [Basecamp CLI](https://github.com/basecamp/basecamp-cli) installed (`curl -fsSL https://basecamp.com/install-cli | bash`) and authenticated (`basecamp auth login`)
- A Basecamp bot user account (for webhook-triggered orchestration)
- brainiac-fizzy plugin (cards already exist in Fizzy)
- brainiac-github plugin (required for `on_pr_merge` and `epic_branch` modes)

## Installation

```bash
brainiac install basecamp
brainiac basecamp setup
```

## Configuration

### Step 1: Set Fizzy Account ID

```bash
brainiac basecamp set fizzy-account-id <your-fizzy-org-id>
```

### Step 2: Map Projects

Find your Basecamp project ID:
```bash
basecamp projects list --jq '.data[] | {id, name}'
```

Map it to your Brainiac project:
```bash
brainiac basecamp projects map stowzilla <basecamp-project-id>
```

### Step 3: Register Bot Account

**Adding an agent:** if the agent is created with Brainiac core, you can skip this step. `brainiac agent create "Galen"` (or `brainiac agent setup galen --only basecamp` for an existing agent) finds the agent's Basecamp person by name — or, after a confirm prompt, invites it by email (`--email` / `agent_email_template`) — adds it to every mapped project, and writes the `bot_accounts` entry. It's idempotent; map projects first. Pass `--skip basecamp` to leave Basecamp out.

**Alternative (manual):** register an existing Basecamp person yourself:
```bash
brainiac basecamp bot add Galen                       # auto-resolves the person ID by name
brainiac basecamp bot add my-server <person-id> Galen # explicit person ID
brainiac basecamp bot sync                            # resolve every agent in ~/.brainiac/agents.json
```

Find a person ID by hand with:
```bash
basecamp people list --jq '.data[] | select(.name | contains("Galen")) | {id, name}'
```

### Step 4: Set Review Gate Mode

```bash
# Simple mode — advance when agent finishes
brainiac basecamp set review-gate on_complete

# PR mode — wait for PR merge to main
brainiac basecamp set review-gate on_pr_merge

# Epic branch mode — review gates + final decision (recommended)
brainiac basecamp set review-gate epic_branch
```

### Step 5: Configure Review Gates (epic_branch mode)

Edit `~/.brainiac/basecamp.json`:

```json
{
  "review_gates": [
    { "agent": "GLaDOS", "role": "test-engineer" },
    { "agent": "Threepio", "role": "code-reviewer" }
  ]
}
```

### Step 6: Configure Notifications (Optional)

```json
{
  "notifications": {
    "channel": "discord",
    "target": "1423854179880927274",
    "epic_started": true,
    "task_dispatched": true,
    "task_completed": true,
    "epic_completed": true
  }
}
```

The `channel` can be any notification backend that subscribes to the `:notify` hook (discord, slack, etc.). The `target` is the channel/room ID for that backend.

### Step 7: Register Webhook

```bash
basecamp webhooks create "https://your-ngrok.ngrok-free.app/basecamp" \
  --types "Todo,Todolist,Comment" --in <basecamp-project-id>
```

Already have webhooks? `brainiac basecamp webhook sync` adds any missing event types to the existing `/basecamp` webhooks on every mapped project.

### Step 8: Restart Brainiac

```bash
brainiac restart
```

## Full Configuration Example

`~/.brainiac/basecamp.json`:

```json
{
  "bot_accounts": {
    "andy-server": {
      "person_id": "52992796",
      "default_agent": "Galen"
    }
  },
  "project_mappings": {
    "stowzilla": { "basecamp_project_id": "45920028" },
    "brainiac": { "basecamp_project_id": "45920028" }
  },
  "epic_prefix": "Epic:",
  "fizzy_account_id": "6098707",
  "review_gate": "epic_branch",
  "review_gates": [
    { "agent": "GLaDOS", "role": "test-engineer" },
    { "agent": "Threepio", "role": "code-reviewer" }
  ],
  "deploy": {
    "enabled": true,
    "trigger": "on_final_pr",
    "default_env": "dev",
    "project_envs": {
      "stowzilla": "dev",
      "posh-nosh": "dev02"
    },
    "command": "belt deploy {env} --auto"
  },
  "notifications": {
    "channel": "discord",
    "target": "1423854179880927274",
    "epic_started": true,
    "task_dispatched": true,
    "task_completed": true,
    "epic_completed": true
  }
}
```

## Epic Deployment

Deploy epics to test environments before merging the final PR to main.

### Per-Epic Deploy Environment

Specify the deploy environment in the epic title or description:

```
Todolist: "Epic: Build Authentication System [deploy:dev02]"
```

Or in the todolist description:

```
deploy:dev02
```

The title syntax takes precedence over description.

### Manual Deploy

```bash
brainiac basecamp deploy <epic-id> [env]
```

Environment resolution (in order):
1. Explicit env argument
2. `[deploy:env]` in epic title
3. `deploy:env` in epic description
4. `deploy.project_envs.<project>` in config (per-project default)
5. `deploy.default_env` in config (global default)

### Automated Deploy

Configure automated deployment in `~/.brainiac/basecamp.json`:

```json
{
  "deploy": {
    "enabled": true,
    "trigger": "on_final_pr",
    "default_env": "dev",
    "project_envs": {
      "stowzilla": "dev",
      "posh-nosh": "dev02"
    },
    "command": "belt deploy {env} --auto"
  }
}
```

| Option | Description |
|--------|-------------|
| `enabled` | Enable/disable automated deploys |
| `trigger` | When to deploy: `manual`, `on_final_pr` |
| `default_env` | Global fallback environment |
| `project_envs` | Per-project default environments (e.g., `{"stowzilla": "dev"}`) |
| `command` | Deploy command template (`{env}` is replaced) |

## CLI Commands

```bash
brainiac basecamp setup                              # Interactive setup
brainiac basecamp config                             # Show config
brainiac basecamp status                             # Plugin health check
brainiac basecamp epics                              # List active epics
brainiac basecamp epics --all [-v]                   # Include completed (-v for detail)
brainiac basecamp deploy <epic-id> [env]             # Deploy epic to environment
brainiac basecamp link <card> <url>                  # Link a Fizzy card to a Basecamp todo
brainiac basecamp bot add <agent>                    # Add bot account (auto-resolves person ID)
brainiac basecamp bot add <name> <id> <agent>        # Add bot account with explicit person ID
brainiac basecamp bot sync                           # Re-resolve bot person IDs from agents.json
brainiac basecamp bot list                           # List bot accounts
brainiac basecamp bot remove <name>                  # Remove a bot account
brainiac basecamp projects map <key> <bc-id>         # Map project
brainiac basecamp projects list                      # List mappings
brainiac basecamp projects unmap <key>               # Remove a mapping
brainiac basecamp set fizzy-account-id <id>          # Set Fizzy account ID
brainiac basecamp set review-gate <mode>             # on_complete, on_pr_merge, epic_branch
brainiac basecamp set epic-prefix <prefix>           # Epic detection prefix
brainiac basecamp set ephemeral-deploys <on|off>     # Ephemeral Belt envs for `deploy`-tagged cards
brainiac basecamp set parent-env <project> <env>     # Parent env ephemeral envs are cloned from
brainiac basecamp reset task <card> [--to <status>]  # Reset a task (default: pending)
brainiac basecamp reset epic <todolist-id> [--to <status>]
brainiac basecamp reset gates <card>                 # Clear gate approvals and re-dispatch
brainiac basecamp scrap <todolist-id> [--confirm]    # Tear down an epic (cards, branches, state)
brainiac basecamp webhook sync                       # Ensure webhooks have required event types
```

## API Endpoints

```bash
# Status
curl http://localhost:4567/api/basecamp

# List epics
curl http://localhost:4567/api/basecamp/epics
curl "http://localhost:4567/api/basecamp/epics?status=all"

# Specific epic
curl http://localhost:4567/api/basecamp/epics/<todolist-id>

# Start an epic manually (no webhook)
curl -X POST http://localhost:4567/api/basecamp/epics \
  -d '{"todolist_id": "...", "project_id": "...", "agent": "Galen", "title": "Epic: ..."}'

# Pause / resume
curl -X POST http://localhost:4567/api/basecamp/epics/<todolist-id>/pause
curl -X POST http://localhost:4567/api/basecamp/epics/<todolist-id>/resume
```

## Self-Healing on Restart

When brainiac restarts, the plugin:

1. Loads active epics from disk
2. For tasks in `in_review` status: syncs gate approvals from GitHub PR reviews
3. If all gates passed: dispatches final decision
4. If all tasks complete: finalizes epic (marks todos done, opens final PR)
5. Dispatches any unblocked pending tasks

No manual intervention needed — just restart and it picks up where it left off.

## Architecture

### Hooks

| Hook | What It Does |
|------|-------------|
| `:agent_completed` | Dispatches review gates after PR opens; advances epic on task completion |
| `:pr_merged` | Advances epic if review gate = `on_pr_merge` |
| `:pr_merged_to_branch` | Advances epic when PR merges to epic branch |
| `:pr_review_received` | Tracks gate approvals; triggers final decision when all gates pass |
| `:pr_synchronized` | Re-triggers review gates after fixes are pushed |
| `:build_brain_context` | Injects epic context + memory references into agent prompts |
| `:resolve_base_branch` | Returns epic branch as worktree base |
| `:resolve_pr_target` | Returns epic branch as PR target |

### Orchestration Flow (Epic Branch Mode)

```
Webhook (todo assigned to bot)
  → Read todolist, build dependency graph
  → Create epic/<name> branch
  → Dispatch unblocked Fizzy cards (parallel if independent)

Card completes, PR opens
  → Dispatch review gate agents (parallel)
  → Gates review and approve/request changes

All gates approve
  → Dispatch implementation agent for final decision
  → Agent reviews feedback, makes fixes if needed, merges PR

PR merged to epic branch
  → Mark Basecamp todo complete
  → Dispatch epic review agent (checks if plan still makes sense)
  → Dispatch next unblocked cards

All tasks complete
  → Open final PR: epic/<name> → main
  → Post summary to Basecamp
  → Send notification
```

## License

MIT
