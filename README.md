# brainiac-basecamp

Basecamp epic orchestration plugin for [Brainiac](https://github.com/stowzilla/brainiac). Manages high-level epics in Basecamp while agents execute individual tasks via Fizzy cards — with dependency tracking, sequential dispatch, review gates, and bidirectional status sync.

## How It Works

1. Create a Basecamp **todolist** with the `Epic:` prefix
2. Add todos to it — each one references a Fizzy card with a clickable link in the description
3. Assign any todo in the list to your bot account
4. The plugin receives the webhook, reads the todolist, builds the dependency graph, and starts orchestrating
5. Unblocked Fizzy cards are assigned to agents automatically
6. As cards complete (and optionally pass review), the plugin marks Basecamp todos done and dispatches the next wave
7. When all tasks finish, a summary message is posted and the epic is marked complete

## Epic Format (Option C: Todolist + Rich Descriptions)

Create a Basecamp todolist:

```
Todolist: "Epic: Build Authentication System"

Todos:
  □ "#1234 — Set up auth models"
      Description: Fizzy: <link to #1234>
                   Depends on: none

  □ "#1235 — Add API endpoints"
      Description: Fizzy: <link to #1235>
                   Depends on: #1234

  □ "#1236 — Frontend login form"
      Description: Fizzy: <link to #1236>
                   Depends on: #1234, #1235
```

Each todo's description contains:
- A **clickable link** to the Fizzy card (`<a href="https://app.fizzy.do/org/cards/1234">#1234</a>`)
- **Dependencies** in `[depends:1234,1235]` or `Depends on: #1234, #1235` format
- Optionally, the assigned **agent** name

The plugin auto-generates these descriptions via `Epic.build_todo_description`.

## Review Gate

Two modes (configured via `brainiac basecamp set review-gate`):

| Mode | Behavior |
|------|----------|
| `on_complete` (default) | Advance to next task as soon as agent finishes |
| `on_pr_merge` | Wait for PR merge before marking task done and unblocking dependents |

The `on_pr_merge` mode hooks into `:pr_merged` events from brainiac-github. This gives you a full review cycle between each epic task.

## Prerequisites

- [Basecamp CLI](https://github.com/basecamp/basecamp-cli) installed and authenticated
- A Basecamp bot user account (for webhook-triggered orchestration)
- brainiac-fizzy plugin (cards already exist in Fizzy)
- brainiac-github plugin (optional, for `on_pr_merge` review gate)

## Setup

```bash
brainiac install basecamp --path /path/to/brainiac-basecamp
brainiac basecamp setup
```

### Configure

```bash
# Set your Fizzy org slug (for generating card URLs in descriptions)
brainiac basecamp set fizzy-org stowzilla

# Map your Basecamp bot user to a local agent
brainiac basecamp bot add andy-server <basecamp-person-id> Galen

# Link Brainiac projects to Basecamp projects
brainiac basecamp projects map marketplace <basecamp-project-id>

# Set review gate mode
brainiac basecamp set review-gate on_pr_merge
```

### Set Up Webhook

```bash
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
  "epic_prefix": "Epic:",
  "fizzy_org": "stowzilla",
  "review_gate": "on_pr_merge",
  "notifications": {
    "epic_started": true,
    "task_dispatched": true,
    "task_completed": true,
    "epic_completed": true
  }
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
brainiac basecamp set fizzy-org <slug>               # Set Fizzy org for URLs
brainiac basecamp set review-gate <mode>             # on_complete or on_pr_merge
brainiac basecamp set epic-prefix <prefix>           # Epic detection prefix
```

## API Endpoints

```bash
# Status
curl http://localhost:4567/api/basecamp

# List epics
curl http://localhost:4567/api/basecamp/epics
curl "http://localhost:4567/api/basecamp/epics?status=all"

# Specific epic with dependency graph
curl http://localhost:4567/api/basecamp/epics/epic-123

# Manually start an epic (for testing)
curl -X POST http://localhost:4567/api/basecamp/epics \
  -H "Content-Type: application/json" \
  -d '{"todolist_id":"123","project_id":"456","agent":"Galen","title":"Epic: Test"}'

# Pause/resume
curl -X POST http://localhost:4567/api/basecamp/epics/epic-123/pause
curl -X POST http://localhost:4567/api/basecamp/epics/epic-123/resume
```

## Architecture

### Hooks

| Hook | What It Does |
|------|-------------|
| `:agent_completed` | Advances epic when Fizzy card completes (respects review gate) |
| `:pr_merged` | Advances epic if review gate = `on_pr_merge` |
| `:build_brain_context` | Injects epic context into agent prompts |

### Orchestration Flow

```
Webhook (todo_assignment_changed)
  → Is parent todolist an epic? (Epic: prefix)
  → Is assigned person a bot account?
  → Start orchestration:
      1. Read all todos in todolist
      2. Parse card refs + dependencies from titles/descriptions
      3. Build dependency graph
      4. Dispatch unblocked Fizzy cards (assign via fizzy CLI)
      5. Wait for :agent_completed / :pr_merged
      6. Mark Basecamp todo complete
      7. Re-evaluate graph → dispatch next
      8. Repeat until all done
      9. Post summary message, emit notification
```

### Dual-Server Pattern

Both brainiac servers receive the same Basecamp webhook. Only the server whose bot account person ID matches an `added_person_id` in the webhook will start orchestration. Same pattern as Fizzy's `local` flag.

## Dependency Tracking

Dependencies are declared in todo titles or descriptions:

**In title:** `#1236 — Frontend [depends:1234,1235]`

**In description (rich text):**
```html
<div>
  <strong>Fizzy:</strong> <a href="https://app.fizzy.do/stowzilla/cards/1236">#1236</a><br>
  <strong>Depends on:</strong> #1234, #1235<br>
</div>
```

The orchestrator:
1. Parses all todos to build a directed acyclic graph
2. Identifies tasks with no unmet dependencies (unblocked)
3. Assigns unblocked Fizzy cards to agents
4. On completion, re-evaluates the graph for newly unblocked tasks
5. Supports mid-epic changes — re-reads the todolist on each cycle

## License

MIT
