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
7. **Match the language of `tasks.raw.md`.** Detect the dominant natural language of `tasks.raw.md` (e.g., Korean vs. English) and write every natural-language field in `tasks.json` — `description`, `acceptance[]`, and any free-form notes — in that same language. If `tasks.raw.md` is in Korean, the task fields must be in Korean; if it is in English, write them in English. Field names, enum values, `scope`, `path`, file paths, identifiers, and code snippets stay verbatim. If `tasks.raw.md` is absent or empty, default to the language used by existing tasks in `tasks.json`; if both are empty, default to English.
8. **Task specs are mutable only before plan completion.** While this phase is still refining the plan, you may edit task spec fields (`id`, `priority`, `scope`, `path`, `description`, `acceptance`, `dependent_on`, `touches`) only when the change is part of the selected planning mode. Every spec change must be explained in the one-line `plan-progress.txt` entry for the iteration. Once `ralph/.plan-complete` exists, build and QA phases must treat those fields as immutable.

## What to do this iteration
Choose exactly **one** of the following modes (in priority order). Planning is
deliberately multi-pass: scope analysis → bootstrap → structural review →
field refinement → coverage close-out → complete. Each iteration moves exactly
one step.

- **MODE A — Scope analysis (must run before bootstrap):** `tasks.json` is empty or `[]` AND `plan-progress.txt` does NOT yet contain a `## Scope analysis` block.

  Read `tasks.raw.md` (if present) and the repository. **Do not write any tasks yet.** Instead, append a `## Scope analysis` block to `plan-progress.txt` covering:
  - **Affected surfaces** — every file, module, route, package, or seam the work will likely touch, with paths grounded in real code (not guessed).
  - **Decisions required** — open design questions the implementer must resolve (e.g., "extend existing helper vs. extract new one?", "where does X live now?").
  - **Risks / cross-cutting concerns** — migrations, public-API exposure, shared-library impact, data-shape changes, ordering constraints.
  - **Atomic unit candidates** — a draft list of work units (one line each); these become tasks in MODE B.

  This block grounds the backlog in the real codebase so MODE B can decompose deliberately instead of paraphrasing the user's request. Exit.

- **MODE B — Bootstrap from analysis:** `tasks.json` is empty or `[]` AND a `## Scope analysis` block exists in `plan-progress.txt`.

  Use the scope analysis to expand the user's request into every atomic task the work actually requires — do not just echo the user's wording back. Each task's `description` and `acceptance[]` should trace back to specific bullets in the analysis (affected surface → task; decision → acceptance criterion).

  Emit as many tasks as the work demands — **there is no upper bound**.
  Calibration ranges (use as guidance, not as caps):

  | Scope of work | Typical task count |
  |---|---|
  | Trivial change (rename, single field) | 1–2 |
  | Single-route feature or bug fix | 3–7 |
  | Domain-wide test/refactor (e.g., e2e for one module) | 10–30 |
  | Cross-cutting refactor or migration | 30+ |

  When in doubt, prefer **more smaller tasks over fewer larger ones**. Catching oversized tasks later via MODE C/D refinement is expensive and tends to bundle unrelated work; over-decomposition only costs extra QA iterations, which are cheap. Exit after writing the initial backlog.

- **MODE C — Structural review (split or merge one task):** No bootstrap pending, but at least one task is structurally problematic. Triggers (in priority order):
  1. **Split candidate** — a single task has ≥4 entries in `acceptance[]`, OR touches ≥2 distinct `workspaces` scopes, OR its `description` joins multiple unrelated outcomes with "and" / "및" / "그리고" / "," / "또한".
  2. **Merge candidate** — two sibling tasks share ≥2 identical or paraphrased acceptance items, or their descriptions describe the same outcome from different angles.

  Pick the first violator. Either split into multiple atomic tasks (preserve the original id on the largest piece; assign fresh ids to the new pieces) or merge two tasks into one (drop the duplicate id). Update every `dependent_on` reference that points at affected ids. Exit.

- **MODE D — Field refinement:** No structural issues remain, but at least one task has a `description` shorter than 40 characters, missing `acceptance`, missing `dependent_on`, or an unverified `scope`.
  Pick the first such task. Read the relevant code under its `path`. Tighten the fields. Exit.

- **MODE E — Coverage close-out (add one task per uncovered raw item):** No structural or field issues remain.

  Build (or rebuild) a `## Coverage map` block at the bottom of `plan-progress.txt`. For each numbered or bulleted requirement in `tasks.raw.md`, write one line: `<short paraphrase> → <task id(s) that cover it, or UNCOVERED>`. If `tasks.raw.md` is absent, write `## Coverage map\n(no tasks.raw.md — coverage trivially complete)` and fall through to MODE F.

  If any line is `UNCOVERED`, add exactly one new task to close the first gap and exit. Otherwise the coverage map is complete; exit and let the next iteration enter MODE F.

- **MODE F — Plan complete:** All tasks have a verified scope, ≥1 acceptance criterion, resolved dependencies, and the latest `## Coverage map` block in `plan-progress.txt` contains zero `UNCOVERED` lines (or notes the absence of `tasks.raw.md`).
  Touch `ralph/.plan-complete` and emit `<promise>PLAN_COMPLETE</promise>`.

## After modifying `tasks.json`
1. Source code linting is **not needed** here (no source changes).
2. Append a one-line entry to `plan-progress.txt`: `iter <n>: <mode> — <short summary>`.
3. **Do not commit.** `ralph/tasks.json`, `ralph/plan-progress.txt`, and `ralph/.plan-complete` are gitignored and persist on disk for the next iteration. The plan phase produces no git history.
4. Output one of:
   - `<promise>NEXT</promise>` — more plan work remains.
   - `<promise>PLAN_COMPLETE</promise>` — backlog is ready for the build phase.

## Output discipline
- Do **not** start writing code. This phase only edits `ralph/tasks.json`, `ralph/plan-progress.txt`, and (on completion) `ralph/.plan-complete`.
- If only one item changes, do **not** rewrite the entire `tasks.json` — preserve all sibling items byte-for-byte.
