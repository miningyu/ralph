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
  ├─ Phase 2 (build)  — implements a small same-scope task batch (build_pass:true)
  │
  └─ Phase 3 (qa)     — independent evaluator validates each task (qa_pass:true)
               └─ on failure → full failure context injected into next build iteration
```

> **Builder** (Claude) implements. **Evaluator** (Codex) validates independently.
> Each phase's CLI is configurable — by default plan/build run on `claude` and QA runs on `codex`,
> so the builder and evaluator come from different model families. Swap in any CLI that accepts a
> prompt as a positional argument (e.g. `claude` on both, or `codex` on both) by editing
> `builder.command` / `evaluator.command` in `ralph/ralph-config.json`.
> QA failures are fed back as root-cause context so the builder fixes the actual problem, not symptoms.

---

## Requirements

- [Claude Code CLI](https://claude.ai/code) (`claude`) — used by Phase 1 (plan) and Phase 2 (build) by default
- [OpenAI Codex CLI](https://github.com/openai/codex) (`codex`) — used by Phase 3 (QA) by default; run `codex login` once before first use
- `bash`, `jq`, `curl`, `git`

> Only the CLIs you actually configure in `ralph/ralph-config.json` need to be installed. If you
> point both `builder.command` and `evaluator.command` at `claude` (or both at `codex`), only that
> one CLI is required.

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

**Phase 2 — Build**: Picks the first `build_pass:false` task, then batches up to `builder.batchSize` ready tasks with the same scope. It runs `commands.quick` for the batch when configured, marks completed tasks `build_pass:true`, and commits once.

After all build tasks pass, the watchdog runs `commands.final` once per touched scope when configured. If `validation.runtimeSmoke` is `"final"`, backend/frontend runtime smoke also runs once at this final gate instead of during every build iteration.

**Phase 3 — QA**: An independent Evaluator agent (not the builder) validates each task against its acceptance criteria. On failure, it writes a detailed bug report to `qa-report.json`. The next build iteration receives the full failure context to fix the root cause. If the same task reaches `evaluator.maxRetries`, Ralph marks it with `qa_status:"blocked"` and stops the watchdog. Missing local prerequisites such as a browser agent, dev server, or credentials are classified as `qa_status:"infra_blocked"`.

If QA finds a regression, the failure report is fed back into the next build context and the cycle repeats until all tasks reach both `build_pass:true` and `qa_pass:true`. Fail-only reports are not committed repeatedly; only meaningful transitions such as pass, fix, blocked, or infra-blocked are committed.

## Configuration

`ralph init` creates `ralph/ralph-config.json` from the template. Key fields:

| Field | Description |
|-------|-------------|
| `projectName` | Used in log messages |
| `workspaces.apps[]` | Apps — name, path, kind (backend/frontend), test flags |
| `workspaces.packages[]` | Shared library entries |
| `commands.*` | build/lint/test/typecheck commands (`{scope}` substituted at runtime) |
| `commands.quick` | Optional fast build-iteration validation command |
| `commands.final` | Optional final validation command run once per touched scope before QA |
| `commands.affected` | Optional cross-task regression command. Prefer a stable base ref such as `${RALPH_BASE_REF:-origin/main}` instead of `HEAD^1` |
| `builder.command` | Agent CLI for plan + build (default: `claude` with Opus) |
| `builder.batchSize` | Maximum number of ready same-scope tasks to build in one agent invocation |
| `evaluator.command` | Agent CLI for QA (default: `codex exec`) — keep this distinct from `builder.command` so QA validates from a fresh perspective |
| `evaluator.maxRetries` | Per-task QA retry cap. When exhausted, the task becomes `qa_status:"blocked"` and the loop stops |
| `validation.runtimeSmoke` | `"perTask"` for legacy build-time smoke, or `"final"` to run runtime smoke once before QA |
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

`qa_status` in `tasks.json` is optional. Missing means the task is still pending QA. `blocked` means Ralph needs human input because retries were exhausted or acceptance criteria conflict with the current codebase. `infra_blocked` means QA could not run because a local prerequisite such as a browser agent, service, or credential is unavailable.

If an existing project uses `HEAD^1` in `ralph-config.json.commands.affected`, change it to a stable base ref or set `RALPH_BASE_REF`. QA/report commits can otherwise become the comparison baseline and make affected checks validate Ralph state changes instead of implementation changes.

## Reset

```bash
ralph reset                        # archive current cycle, start fresh
ralph reset path/to/new-raw.md     # reset and load new requirements
ralph reset --hard                 # clear without archiving
```

## License

MIT
