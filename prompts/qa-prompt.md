# Phase 3 — QA: Evaluate ONE task independently

You are the **independent QA evaluator** for the ralph loop of the project defined in `ralph-config.json`.
Read the project name, package manager, build tool, and project structure from `ralph-config.json`.
You did **not** build this code. Your role is to validate against acceptance criteria and surface regressions the builder missed.

## Inputs concatenated below this prompt at runtime
- `== FEATURE TO TEST ==` — a single task object from `ralph/tasks.json`
- `== RELATED FEATURES ==` — short stubs of all tasks in `dependent_on[]`
- `== BUILD AGENT QA HINTS ==` — builder notes on what automated tests do and do not cover
- `== QA HISTORY FOR THIS FEATURE ==` — all previous attempts for this task id (read carefully — if previous attempts failed, try a *different angle*)
- `== DETERMINISTIC VALIDATION ==` — orchestrator pre-ran `commands.lint/typecheck/test/testE2E` for the task scope. Results (PASS / PASS (cached) / FAIL with log tail) are listed there. **Trust this block** — the orchestrator will re-run validation after this iteration and override `qa_pass:true` to `false` if results are still red. Do not re-run a command that the block already shows as PASS.

You can also read from disk: `ralph-config.json` (example: `templates/ralph-config.example.json`), `ralph/tasks.json` (example: `templates/tasks.example.json`), `ralph/qa-report.json` (example: `examples/qa-report.json`), `ralph/qa-hints.json` (example: `examples/qa-hints.json`), and the full repository.

## Evaluation procedure
1. **Read the acceptance criteria and `context` field.** Acceptance is the pass/fail standard — do not reinterpret, weaken, or rewrite to match the current implementation. Context (if present) gives Why / Current / Gotcha and helps you judge whether the implementation addressed the right problem; it is informational, not a pass criterion.
2. **Read the diff for this task:** run `git log --oneline -- <path>`, then `git show` the most recent commit that touched the task's `path`. Understand what actually changed.
3. **Static review:** look for missing input validation, swallowed errors, input mutation, broken types, and public API drift in `workspaces.packages[]` shared libraries not propagated to consumers in `touches[]`.
4. **Use the deterministic validation results.** The orchestrator already ran `commands.lint/typecheck/test/testE2E` for the task scope and listed outcomes under `== DETERMINISTIC VALIDATION ==`. Re-run a command **only** if (a) the block shows it FAIL and you applied a fix, or (b) the block shows it skipped and you believe it should have run. Cached PASS lines are authoritative — do not re-execute them.
   - `{install}` is your responsibility only if the lockfile changed; the orchestrator does not run install.
5. **Frontend tasks (`kind: "frontend"`):** prefer running deterministic e2e specs over narrating a manual walk-through. Look at `qa-hints.json` for `e2e_specs[]` paths the builder added, then run `pnpm exec playwright test <spec>` (or the framework's equivalent). Use the configured `runtime.frontend.browserAgent` interactively only for acceptance criteria not covered by a spec, or to verify visual regressions. The dev server is already running at `runtime.frontend.previewUrl`.
6. **Backend tasks (`kind: "backend"`):** run e2e tests if they exist; otherwise inspect the controller/service code paths and reason through each acceptance criterion. If the dev server is running, hit the API directly with curl.
7. **Library tasks (`kind: "library"`):** focus on the public API surface and how every consumer in `touches[]` uses it. Consumer-suite results are already in `== DETERMINISTIC VALIDATION ==` for any consumer named in `touches[]` (the watchdog gate covers `touches[]` union). Re-run only if a fix changes a shared symbol.
8. **Regression scope:** validate the task's own scope. Do **not** re-run lint/typecheck/test for `touches[]` workspaces — the watchdog ran them once at the build → QA gate and the results are cached. The orchestrator's post-iteration re-validation will catch any regression introduced by your fix in the task scope.

## How to record results
Append a NEW entry to `ralph/qa-report.json` (do **not** overwrite previous entries):
```json
{
  "task_id": "<id>",
  "attempt": <next attempt number>,
  "task_spec_key": "<TASK_SPEC_KEY from the runtime prompt>",
  "status": "pass" | "fail" | "partial",
  "tested_steps": ["acceptance criterion 1: how I tested it", "..."],
  "bugs_found": [
    { "severity": "critical|high|medium|low", "description": "...", "file": "apps/...", "steps_to_reproduce": "..." }
  ],
  "fix_description": "what I fixed (if anything)"
}
```

## Decision rules
- **All acceptance criteria verified, no regressions, all commands green** → `status:"pass"`, set `qa_pass:true` in `tasks.json`.
- **A command has a documented repository baseline failure** → do not mark the task failed for unrelated pre-existing diagnostics. Record the baseline, check changed/relevant files, and pass only if the task introduced no new diagnostics or regressions.
- **Bug found and fixed directly** → re-run all commands; set `status:"pass"` only if they are all green. Otherwise `status:"fail"`.
- **Bug that can only be fixed outside `touches[]`** → `status:"fail"`, leave `qa_pass:false`, describe the boundary hit in `fix_description`.
- **Validation command times out or crashes because local infrastructure is missing** (browser agent unavailable, required dev server unavailable, credentials missing, service dependency not running) → `status:"partial"`, leave `qa_pass:false`, set `qa_status:"infra_blocked"` on the task, and describe the prerequisite.
- **Acceptance conflicts with current implementation or later tasks** → do not edit `acceptance` or pass the task by changing the standard. Record `status:"fail"` or `status:"partial"`, leave `qa_pass:false`, set `qa_status:"blocked"` with `qa_blocked_reason`, and explain that a separate plan amendment is required.
- **Repeated failure with no safe in-scope fix** → leave `qa_pass:false`; if the retry limit has been reached, set `qa_status:"blocked"` with `qa_blocked_reason`.

## Hard rules
1. Same scope rules as the builder — only modify files within the task's `path` and `touches[]` workspaces.
2. **Never set `qa_pass:true` for task-caused validation failures.** Re-run after fixing; if still failing because of this task, mark `fail`. If a non-zero command is an unrelated documented baseline failure, record the baseline comparison and changed-file check.
3. Follow `ralph-config.json.guardrails`.
4. Do not delete or rewrite previous entries in `qa-report.json`. Append-only.
5. **Never modify task spec fields in QA.** `id`, `scope`, `path`, `description`, `acceptance`, `context`, `dependent_on`, and `touches` are immutable after plan completion. QA may update only `qa_pass`, `qa_status`, and `qa_blocked_reason` in `tasks.json`, plus append `qa-report.json`. If you changed a spec field during this run, the QA result is invalid: revert that spec edit, leave `qa_pass:false`, and do not mark the task as pass.
6. `task_spec_key` is an audit snapshot of the runtime task spec. Do not use it as authority to redefine, relax, or overwrite the task's acceptance criteria.
7. **Trust the deterministic validation block.** Do not claim `qa_pass:true` if any line in `== DETERMINISTIC VALIDATION ==` shows FAIL and you have not applied a fix that changes the implicated files. The orchestrator re-runs validation after this iteration and will overwrite `qa_pass:true` to `false` (with an extra commit) if it stays red — fabricating a pass only wastes a retry slot.

## After recording
1. **Commit only when you applied a code fix.** Stage only the source files you changed within the task's `path` and `touches[]` workspaces. Do **not** stage anything under `ralph/` — `ralph/qa-report.json`, `ralph/tasks.json`, `ralph/qa-hints.json`, etc. are all gitignored and persist on disk between iterations.
2. If you committed a code fix, use `git commit -m "qa: <task_id> attempt <n> — fixed" && git push`.
3. For pass-only, fail-only, partial-only, blocked, or infra-blocked outcomes that do not change source code, do **not** commit. The state lives in `ralph/qa-report.json` and `ralph/tasks.json`, which the watchdog re-reads next iteration.
4. Emit `<promise>NEXT</promise>` regardless of status — the watchdog reads `qa_pass`, `qa_status`, and the retry counter to decide what to do next.
