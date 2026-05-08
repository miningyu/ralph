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

After all build tasks pass, the watchdog runs the **build → QA gate**: it iterates the union of every task's `scope` and `touches[]`, runs `commands.lint/typecheck/test` per workspace once, and writes each result into the QA cache (`ralph/.qa-cache/`). Per-task QA later reuses these cached results, so the same lint/test run is never re-executed for unchanged code. If `validation.runtimeSmoke` is `"final"`, backend/frontend runtime smoke also runs once at this gate. Legacy `commands.final` is honored only when no individual `commands.lint/typecheck/test` are configured.

**Phase 3 — QA**: An independent Evaluator agent (not the builder) validates each task against its acceptance criteria. The orchestrator drives validation deterministically:

1. **No-op skip** — If the task previously reached `qa_pass:true` and no file in its `path ∪ touches[]` has changed since (tracked via `git_sha` on each `qa-report.json` entry), the LLM evaluator is **not** invoked; `qa_pass:true` is set and the task is committed as a no-op skip.
2. **Pre-validation** — Before invoking the LLM, the orchestrator runs `commands.lint/typecheck/test/testE2E` for the task's scope (or hits the QA cache populated by the gate) and injects results into the prompt as `== DETERMINISTIC VALIDATION ==`. The evaluator reasons over those results instead of running commands itself.
3. **Per-kind timeout** — `evaluator.iterationTimeoutSeconds` is the default (600s); override per kind with `evaluator.kindTimeoutOverride` (e.g. `{"frontend": 1800}`).
4. **Post-LLM recheck** — After the evaluator finishes, the orchestrator re-runs scope validation. If results are still red but the evaluator claimed `qa_pass:true`, the orchestrator overrides `qa_pass` back to `false` with an extra commit. This blocks the failure mode where the LLM rationalises a fail as a pass.

On failure, the evaluator writes a detailed bug report to `qa-report.json`. The next build iteration receives the full failure context to fix the root cause. If the same task reaches `evaluator.maxRetries`, Ralph marks it `qa_status:"blocked"` and stops the watchdog. Missing local prerequisites such as a browser agent, dev server, or credentials are classified as `qa_status:"infra_blocked"`.

If QA finds a regression, the failure report is fed back into the next build context and the cycle repeats until all tasks reach both `build_pass:true` and `qa_pass:true`. Fail-only reports are not committed repeatedly; only meaningful transitions such as pass, fix, blocked, or infra-blocked are committed.

## Configuration

`ralph init` creates `ralph/ralph-config.json` from the template. Key fields:

| Field | Description |
|-------|-------------|
| `projectName` | Used in log messages |
| `workspaces.apps[]` | Apps — name, path, kind (backend/frontend), test flags |
| `workspaces.packages[]` | Shared library entries |
| `commands.*` | build/lint/test/typecheck commands (`{scope}` substituted at runtime). Individual `lint/typecheck/test/testE2E` are preferred — the watchdog uses them at the build → QA gate to populate the QA cache, and per-task QA reuses cached results. |
| `commands.quick` | Optional fast build-iteration validation command |
| `commands.final` | Legacy. Used only when none of the individual `commands.lint/typecheck/test` are configured. With individual commands present, the gate runs each one and caches the result instead. |
| `builder.command` | Agent CLI for plan + build (default: `claude` with Opus) |
| `builder.batchSize` | Maximum number of ready same-scope tasks to build in one agent invocation |
| `evaluator.command` | Agent CLI for QA (default: `codex exec`) — keep this distinct from `builder.command` so QA validates from a fresh perspective |
| `evaluator.maxRetries` | Per-task QA retry cap. When exhausted, the task becomes `qa_status:"blocked"` and the loop stops |
| `evaluator.iterationTimeoutSeconds` | Default LLM evaluator timeout per task (default: 600s). |
| `evaluator.kindTimeoutOverride` | Per-`kind` timeout overrides, e.g. `{"frontend": 1800}` for frontend tasks that drive a browser agent. |
| `evaluator.cacheDir` | Where the QA cache is stored. Default: `ralph/.qa-cache`. Safe to delete to force a clean re-validation. |
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
| `ralph/qa-report.json` | Per-task QA attempt history. Each entry is stamped with `git_sha` so the orchestrator can detect "no-op since last pass" and skip the LLM. |
| `ralph/qa-hints.json` | Builder hints for the QA evaluator. For frontend tasks, builder lists deterministic e2e specs under `e2e_specs[]` so QA can run them instead of narrating a manual browser walk-through. |
| `ralph/.qa-cache/` | Per-`(scope, content)` validation cache used by the build → QA gate and per-task QA. Generated; safe to delete. |
| `ralph/.plan-complete` | Sentinel — Phase 1 is done |

`qa_status` in `tasks.json` is optional. Missing means the task is still pending QA. `blocked` means Ralph needs human input because retries were exhausted or acceptance criteria conflict with the current codebase. `infra_blocked` means QA could not run because a local prerequisite such as a browser agent, service, or credential is unavailable.

## Reset

```bash
ralph reset                        # archive current cycle, start fresh
ralph reset path/to/new-raw.md     # reset and load new requirements
ralph reset --hard                 # clear without archiving
```

## License

MIT
