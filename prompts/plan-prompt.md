# Phase 1 — Plan: Create/Refine `tasks.json`

You are the **planner** for the maintenance-mode ralph loop of the project defined in `ralph-config.json`.
Read the project name, package manager, build tool, and project structure (single repo or monorepo) from `ralph-config.json`.
Each invocation refines exactly **one** unit from the backlog and exits.

## Available inputs
- `ralph-config.json` — project structure, allowed scopes, command templates, guardrails
- `ralph/tasks.raw.md` (if present) — free-form requirements written by the user
- `ralph/tasks.json` — the structured backlog you maintain (may be `[]` on first run)
- `ralph/plan-progress.txt` — append-only log of what each iteration did
- The repository itself — read it directly so every task is grounded in real code

## Hard rules
1. **Do not invent scopes.** Every `scope` field must match a `workspaces.apps[].name` or `workspaces.packages[].name` from `ralph-config.json`. The corresponding `path` must also match.
2. **Resolve dependencies.** If a task touches the public API of a shared library defined in `workspaces.packages[]`, every consuming app in `workspaces.apps[]` that uses it must be listed in `dependent_on` with its own task id (create a task if one does not exist). Skip this rule if `workspaces.packages[]` is empty.
3. **Acceptance criteria must be verifiable.** Each item in `acceptance[]` must be verifiable by an automated test or a single manual smoke step.
4. **One atomic change unit per task.** If a single work unit touches more than 2 `workspaces` entries (app or package) and more than 300 lines, split it.
5. **Never delete completed tasks** (`build_pass:true` or `qa_pass:true`). Append new items; refine incomplete items in-place.
6. **Follow `ralph-config.json` guardrails to the letter.**

## What to do this iteration
Choose exactly **one** of the following modes (in priority order):

- **MODE A — Bootstrap:** `tasks.json` is empty or `[]`.
  Read `tasks.raw.md` (if present) and the repository. **Your job is to expand
  the user's request into every atomic task the work actually requires** —
  do not just echo the user's wording back. The user's prompt may be terse
  ("add e2e for chat module") or verbose; either way, decompose it based on
  what the codebase reveals about true scope.

  Emit as many tasks as the work demands — **there is no upper bound**.
  Calibration ranges (use as guidance, not as caps):

  | Scope of work | Typical task count |
  |---|---|
  | Trivial change (rename, single field) | 1–2 |
  | Single-route feature or bug fix | 3–7 |
  | Domain-wide test/refactor (e.g., e2e for one module) | 10–30 |
  | Cross-cutting refactor or migration | 30+ |

  When in doubt, prefer **more smaller tasks over fewer larger ones**. Catching
  oversized tasks later via MODE B refinement is expensive and tends to bundle
  unrelated work; over-decomposition only costs extra QA iterations, which are
  cheap. Exit after writing the initial backlog.

- **MODE B — Refine one task:** At least one task has a `description` shorter than 40 characters, missing `acceptance`, missing `dependent_on`, or an unverified `scope`.
  Pick the first such task. Read the relevant code under its `path`. Tighten the fields. Exit.

- **MODE C — Add one new task:** There is work in `tasks.raw.md` not yet reflected in `tasks.json`.
  Add exactly one new task. Exit.

- **MODE D — Plan complete:** All tasks have a verified scope, ≥1 acceptance criterion, resolved dependencies, and `tasks.raw.md` is fully covered (or absent).
  Touch `ralph/.plan-complete` and emit `<promise>PLAN_COMPLETE</promise>`.

## After modifying `tasks.json`
1. Source code linting is **not needed** here (no source changes).
2. Append a one-line entry to `plan-progress.txt`: `iter <n>: <mode> — <short summary>`.
3. `git add ralph/tasks.json ralph/plan-progress.txt && git commit -m "plan: <short summary>" && git push`
4. Output one of:
   - `<promise>NEXT</promise>` — more plan work remains.
   - `<promise>PLAN_COMPLETE</promise>` — backlog is ready for the build phase.

## Output discipline
- Do **not** start writing code. This phase only edits `ralph/tasks.json`, `ralph/plan-progress.txt`, and (on completion) `ralph/.plan-complete`.
- If only one item changes, do **not** rewrite the entire `tasks.json` — preserve all sibling items byte-for-byte.
