# ralph

Autonomous build loop for [Claude Code](https://claude.ai/code). Runs **plan → build → QA** in a self-correcting cycle using two Claude agents (builder + evaluator) with automatic retry and regression recovery.

```
ralph-watchdog.sh
  ├─ Phase 1: plan-ralph.sh    — refines tasks.json until .plan-complete
  ├─ Phase 2: build-ralph.sh   — implements tasks until all are build_pass:true
  └─ Phase 3: qa-ralph.sh      — validates tasks until all are qa_pass:true
               └─ on failure → back to Phase 2 (rebuild with root-cause context)
```

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- `bash`, `jq`, `curl`
- `git` (commits are used for state persistence between iterations)

## Setup

**1. Copy ralph into your project root:**
```bash
cp -r ralph/ your-project/ralph/
```

**2. Configure:**
```bash
cp ralph/ralph-config.example.json ralph/ralph-config.json
# Edit ralph/ralph-config.json for your project
```

**3. Write requirements (optional):**
```bash
# Free-form requirements — the planner will structure them into tasks.json
echo "Add user auth with JWT" >> ralph/tasks.raw.md
```

**4. Run:**
```bash
./ralph/ralph-watchdog.sh
```

Or run phases individually:
```bash
./ralph/plan-ralph.sh      # Phase 1 only
./ralph/build-ralph.sh     # Phase 2 only
./ralph/qa-ralph.sh        # Phase 3 only
```

## Configuration

Copy `ralph/ralph-config.example.json` to `ralph/ralph-config.json` and fill in your project details. Key fields:

| Field | Description |
|-------|-------------|
| `projectName` | Used in log messages |
| `packageManager` | `pnpm`, `npm`, `yarn`, etc. |
| `workspaces.apps[]` | App entries with name, path, kind (backend/frontend), test flags |
| `workspaces.packages[]` | Shared library entries |
| `commands.*` | Build, lint, test, typecheck commands (`{scope}` is substituted at runtime) |
| `evaluator.command` | Claude command for QA agent (Sonnet recommended) |
| `builder.command` | Claude command for build agent (Opus recommended) |
| `runtime.backend` | Port, health path, dev command for backend auto-restart |
| `runtime.frontend` | Dev command, preview URL for browser-based QA |
| `guardrails[]` | Hard rules injected into every agent prompt |

## Files

| File | Purpose |
|------|---------|
| `ralph-watchdog.sh` | Top-level orchestrator — run this |
| `plan-ralph.sh` | Phase 1: planner agent loop |
| `build-ralph.sh` | Phase 2: builder agent loop |
| `qa-ralph.sh` | Phase 3: evaluator agent loop |
| `reset-ralph.sh` | Archive previous cycle state and start fresh |
| `ralph-lib.sh` | Shared shell utilities |
| `ralph-config.example.json` | Configuration template |
| `tasks.example.json` | Example tasks.json structure |
| `plan-prompt.md` | System prompt for the planner agent |
| `build-prompt.md` | System prompt for the builder agent |
| `qa-prompt.md` | System prompt for the QA evaluator agent |

## State files (gitignored by default)

| File | Description |
|------|-------------|
| `ralph/tasks.json` | Structured backlog with build_pass / qa_pass flags |
| `ralph/tasks.raw.md` | Free-form requirements input |
| `ralph/qa-report.json` | Per-task QA attempt history |
| `ralph/qa-hints.json` | Builder hints for the QA evaluator |
| `ralph/plan-progress.txt` | Planner iteration log |
| `ralph/build-progress.txt` | Builder iteration log |
| `.plan-complete` | Sentinel file — Phase 1 is done |

## Reset

```bash
./ralph/reset-ralph.sh                        # archive state, clear for new cycle
./ralph/reset-ralph.sh path/to/new-raw.md     # reset + load new requirements
./ralph/reset-ralph.sh --hard                 # clear without archiving
```

## License

MIT
