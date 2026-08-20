# brainiac-basecamp

Basecamp epic orchestration plugin for [Brainiac](https://github.com/stowzilla/brainiac). Manages high-level epics in Basecamp while agents execute individual tasks via Fizzy cards — with dependency tracking, sequential dispatch, and bidirectional status sync.

## How It Works

1. Create a Basecamp todo with the `Epic:` prefix and subtasks referencing Fizzy cards
2. Assign the todo to your bot account in Basecamp
3. The plugin receives the webhook, parses the dependency graph, and starts orchestrating
4. Unblocked Fizzy cards are assigned to agents automatically
5. As cards complete, the plugin marks Basecamp subtasks done and dispatches the next wave
6. When all tasks finish, the epic is marked complete with a summary comment

## Epic Format

Create a Basecamp todo like this:

```
Title: Epic: Build Authentication System

Subtasks:
  □ #1234 — Set up auth models
  □ #1235 — Add login endpoint
  □ #1236 — Frontend login form [depends:1234,1235]
  □ #1237 — E2E tests [depends:1236]
```

Each subtask references a Fizzy card number (`#NNNN`) and optionally declares dependencies with `[depends:card,card]`.

## Prerequisites

- [Basecamp CLI](https://github.com/basecamp/basecamp-cli) installed and authenticated
- A Basecamp bot user account (for webhook-triggered orchestration)
- Fizzy integration configured (cards already exist)

## Setup

```bash
brainiac install basecamp --path /path/to/brainiac-basecamp
brainiac basecamp setup
```

### Configure Bot Account

```bash
# Map your Basecamp bot user to a local agent
brainiac basecamp bot add andy-server <basecamp-person-id> Galen
```

### Map Projects

```bash
# Link Brainiac projects to Basecamp projects
brainiac basecamp projects map marketplace <basecamp-project-id>
```

### Set Up Webhook

```bash
# Register the webhook on your Basecamp project
basecamp webhooks create "https://your-ngrok.ngrok-free.app/basecamp" \
  --types "Todo,Todolist" --in <project>
```

## Configuration

`~/.brainiac/basecamp.json`:

```json
{
  "bot_accounts": {
    "andy-server": {
      "person_id": "12345",
      "default_agent": "Galen"
    }
  },
  "project_mappings": {
    "marketplace": {
      "basecamp_project_id": "67890"
    }
  },
  "epic_prefix": "Epic:"
}
```

## CLI Commands

```bash
brainiac basecamp setup                              # Interactive setup
brainiac basecamp config                             # Show config
brainiac basecamp status                             # Plugin health check
brainiac basecamp epics                              # List active epics
brainiac basecamp epics --all                        # Include completed
brainiac basecamp bot add <name> <id> <agent>        # Add bot account
brainiac basecamp bot list                           # List bot accounts
brainiac basecamp projects map <key> <bc-id>         # Map project
brainiac basecamp projects list                      # List mappings
```

## API Endpoints

```bash
curl http://localhost:4567/api/basecamp               # Plugin status
curl http://localhost:4567/api/basecamp/epics          # Active epics
curl http://localhost:4567/api/basecamp/epics/epic-123 # Specific epic + dep graph
```

## Architecture

The plugin hooks into Brainiac's event system:

- **Inbound webhook** (`POST /basecamp`): Receives `todo_assignment_changed` events from Basecamp
- **`:agent_completed` hook**: Advances epic orchestration when a Fizzy card session finishes
- **Orchestrator**: State machine per epic — tracks deps, dispatches cards, syncs status

Both brainiac servers receive the same webhook. Only the server whose bot account person ID matches will start orchestration (same pattern as Fizzy's `local` flag).

## Dependency Tracking

Dependencies are declared in subtask titles: `[depends:1234,1235]`

The orchestrator:
1. Parses all subtask titles to build a directed acyclic graph
2. Identifies tasks with no unmet dependencies (unblocked)
3. Assigns unblocked Fizzy cards to agents
4. On completion, re-evaluates the graph for newly unblocked tasks
5. Repeats until all tasks complete

## License

MIT
