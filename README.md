# simple-ralph

[한국어](./README.ko.md)

**Splits a single prompt into multiple tasks, then autonomously runs plan → build → QA until every task is done.**

```
ralph run
  │
  ├─ Phase 1 (plan)   — parses your prompt into discrete tasks
  │                     "Add JWT auth with refresh token"
  │                     → [T-001] JWT strategy  [T-002] refresh endpoint  [T-003] guard ...
  │
  ├─ Phase 2 (build)  — implements one task per iteration (build_pass:true)
  │
  └─ Phase 3 (qa)     — independent evaluator validates each task (qa_pass:true)
               └─ on failure → full failure context injected into next build iteration
```

> **Builder** (Opus) implements. **Evaluator** (Sonnet) validates independently.
> QA failures are fed back as root-cause context so the builder fixes the actual problem, not symptoms.

---

## Requirements

- [Claude Code CLI](https://claude.ai/code) (`claude`)
- `bash`, `jq`, `curl`, `git`

## Install

```bash
git clone https://github.com/miningyu/simple-ralph ~/.ralph
~/.ralph/install.sh
```

Add to your shell profile if needed:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Quick Start

```bash
cd your-project

ralph init                                   # create ralph/ralph-config.json
# edit ralph/ralph-config.json

echo "Add JWT auth with refresh token" >> ralph/tasks.raw.md
ralph run                                    # split into tasks → loop until done
```

Run phases individually:
```bash
ralph plan    # phase 1: tasks.raw.md → tasks.json
ralph build   # phase 2: implement
ralph qa      # phase 3: validate
ralph reset   # archive current cycle, start fresh
```

## How It Works

**Phase 1 — Plan**: Reads free-form requirements from `tasks.raw.md` and breaks them into structured tasks in `tasks.json`. Each task gets a scope, acceptance criteria, and dependency links.

**Phase 2 — Build**: Picks the first `build_pass:false` task and implements it. Runs lint → typecheck → test → runtime smoke before marking `build_pass:true` and committing.

**Phase 3 — QA**: An independent Evaluator agent (not the builder) validates each task against its acceptance criteria. On failure, it writes a detailed bug report to `qa-report.json`. The next build iteration receives the full failure context to fix the root cause.

If QA finds a regression, `build_pass` is reset and the cycle repeats until all tasks reach both `build_pass:true` and `qa_pass:true`.

## Configuration

`ralph init` creates `ralph/ralph-config.json` from the template. Key fields:

| Field | Description |
|-------|-------------|
| `projectName` | Used in log messages |
| `workspaces.apps[]` | Apps — name, path, kind (backend/frontend), test flags |
| `workspaces.packages[]` | Shared library entries |
| `commands.*` | build/lint/test/typecheck commands (`{scope}` substituted at runtime) |
| `builder.command` | Claude command for build agent (Opus recommended) |
| `evaluator.command` | Claude command for QA agent (Sonnet recommended) |
| `runtime.backend` | Port, health path, dev command for backend auto-restart |
| `runtime.frontend` | Dev command, preview URL for browser-based QA |
| `guardrails[]` | Rules injected into every agent prompt |

See `templates/ralph-config.example.json` for a full example.

## Project State

After `ralph init`, your project gets a `ralph/` directory:

| File | Description |
|------|-------------|
| `ralph/ralph-config.json` | Project config — commit this |
| `ralph/tasks.raw.md` | Free-form requirements input |
| `ralph/tasks.json` | Task backlog with `build_pass` / `qa_pass` flags |
| `ralph/qa-report.json` | Per-task QA attempt history |
| `ralph/qa-hints.json` | Builder hints for the QA evaluator |
| `ralph/.plan-complete` | Sentinel — Phase 1 is done |

## Reset

```bash
ralph reset                        # archive current cycle, start fresh
ralph reset path/to/new-raw.md     # reset and load new requirements
ralph reset --hard                 # clear without archiving
```

## License

MIT
