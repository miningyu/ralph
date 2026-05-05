# ralph

Autonomous build loop for [Claude Code](https://claude.ai/code). Runs **plan → build → QA** in a self-correcting cycle using two Claude agents — a builder and an independent evaluator.

```
ralph run
  ├─ Phase 1 (plan)   — structures requirements into tasks.json
  ├─ Phase 2 (build)  — implements tasks until all are build_pass:true
  └─ Phase 3 (qa)     — validates tasks until all are qa_pass:true
               └─ on failure → back to Phase 2 with root-cause context
```

## Requirements

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (`claude`)
- `bash`, `jq`, `curl`, `git`

## Install

```bash
git clone https://github.com/miningyu/ralph ~/.ralph
~/.ralph/install.sh
```

Then add to your shell profile if needed:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Usage

```bash
cd your-project

ralph init          # scaffold ralph/ralph-config.json
# edit ralph/ralph-config.json for your project

echo "Add JWT auth" >> ralph/tasks.raw.md
ralph run           # plan → build → QA
```

Run phases individually:
```bash
ralph plan          # phase 1 only
ralph build         # phase 2 only
ralph qa            # phase 3 only
ralph reset         # archive current cycle, start fresh
```

## Configuration

`ralph init` creates `ralph/ralph-config.json` from the template. Key fields:

| Field | Description |
|-------|-------------|
| `projectName` | Used in log messages |
| `packageManager` | `pnpm`, `npm`, `yarn`, etc. |
| `workspaces.apps[]` | Apps with name, path, kind (backend/frontend), test flags |
| `workspaces.packages[]` | Shared library entries |
| `commands.*` | Build, lint, test, typecheck commands (`{scope}` substituted at runtime) |
| `builder.command` | Claude command for build agent (Opus recommended) |
| `evaluator.command` | Claude command for QA agent (Sonnet recommended) |
| `runtime.backend` | Port, health path, dev command for backend auto-restart |
| `runtime.frontend` | Dev command, preview URL for browser-based QA |
| `guardrails[]` | Rules injected into every agent prompt |

See `templates/ralph-config.example.json` for a full example.

## Project state (gitignored)

After `ralph init`, your project gets a `ralph/` directory for cycle state:

| File | Description |
|------|-------------|
| `ralph/ralph-config.json` | Project configuration (commit this) |
| `ralph/tasks.raw.md` | Free-form requirements input |
| `ralph/tasks.json` | Structured backlog with build_pass / qa_pass flags |
| `ralph/qa-report.json` | Per-task QA attempt history |
| `ralph/qa-hints.json` | Builder hints for the QA evaluator |
| `.plan-complete` | Sentinel — Phase 1 is done |

## Reset

```bash
ralph reset                        # archive state, clear for new cycle
ralph reset path/to/new-raw.md     # reset and load new requirements
ralph reset --hard                 # clear without archiving
```

## License

MIT
