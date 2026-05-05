# Phase 2 — Build: Implement exactly ONE task

You are the **builder** for the maintenance-mode ralph loop of the project defined in `ralph-config.json`.
Read the project name, package manager, build tool, and project structure (single repo or monorepo) from `ralph-config.json`.
Each invocation completes exactly **one** task from `ralph/tasks.json` and exits.

## Available inputs
- `ralph-config.json` — project structure, allowed scopes, command templates, guardrails
- `ralph/tasks.json` — the refined backlog from Phase 1
- `ralph/build-progress.txt` — append-only log of past iterations
- `ralph/qa-report.json` — Phase 3 evaluator output (populated only after the first QA pass)
- `ralph/qa-hints.json` — builder notes for the QA evaluator (appendable)

## Selecting exactly ONE task
Iterate through `tasks.json` in order. The target task is the **first item with `build_pass == false`**.

If any task in the target's `dependent_on[]` has `build_pass != true`, **stop immediately and emit `<promise>BLOCKED</promise>`** — this signals that Phase 1 set the order incorrectly.

## Modes

- **FRESH BUILD:** No entry for this task id exists in `qa-report.json`. Implement from scratch.
- **REBUILD (root-cause fix):** One or more failed attempts for this task id exist in `qa-report.json`.
  Read **all** failed attempt entries. Bugs are rarely at the location the QA report points to; they are typically in:
    - Shared utilities in `workspaces.packages[]` that the failing component depends on, or
    - Data shape mismatches between a shared library's public types and its consumers, or
    - Tests that mock something the runtime no longer guarantees.
  Trace the root cause through the full `dependent_on` chain. Fix it once, correctly — do not patch symptom by symptom.

## Hard rules
1. **Work only within `scope` and `touches`.** You may read any file, but modifications are only allowed within the task's `path` and paths listed in `touches[]`. If a fix requires changing a component not in `touches[]`, stop and instead append a new task with `build_pass:false` to `tasks.json`, then emit `<promise>NEXT</promise>`.
2. **Follow `ralph-config.json` guardrails to the letter.**
3. **Do not modify package manager configuration.** Do not edit lockfiles or workspace config files (e.g. `pnpm-workspace.yaml`, `package.json` workspaces field). Do not introduce build commands not present in `ralph-config.json`'s `commands.*`.
4. **Update tests in the same iteration.** Every new behavior must have at least one test (if a test runner exists for that component — check `hasTests` in `ralph-config.json`). If `hasE2E:true` for a backend and the change affects a request path, extend e2e tests as well.
5. **Propagate public API changes.** If you change an exported symbol from a shared library in `workspaces.packages[]`, every consumer in `touches[]` must compile and pass tests within the same iteration.

## Required validation before committing
Run the following for the task's scope, in order:
```
{install}     # only if lockfile or package config files changed
{lint}
{typecheck}   # if the framework supports it
{test}
{testE2E}     # only if hasE2E:true and scope is the changed component
```
Substitute templates from `ralph-config.json.commands.*`, replacing `{scope}` with the task's `scope` value. **All commands must exit 0.** If any step fails, fix the cause and re-run.

## Runtime validation (runtime.backend.affectedScopes only)
If the task's `scope` is listed in `ralph-config.json`'s `runtime.backend.affectedScopes` array, the **live service** must also be clean after all static checks pass before setting `build_pass:true`. Skip this entire section otherwise.

Rationale: static builds only guarantee compilability. Bugs that compile but break at runtime must be caught here and fixed in the same iteration.

Read the following from `ralph-config.json`:
- `runtime.backend.port` — backend server port
- `runtime.backend.healthPath` — backend health check path
- `runtime.backend.devCommand` — backend dev server start command (managed by build-ralph.sh)
- `runtime.backend.logDir` — backend error log directory
- `runtime.backend.errorLogWhitelist` — array of error patterns to ignore as normal noise
- `runtime.frontend.port` — frontend server port
- `runtime.frontend.previewUrl` — frontend verification URL
- `runtime.frontend.devCommand` — frontend dev server start command

### 1) Start services
The backend (`runtime.backend.port`) is already started and verified by build-ralph.sh before each iteration. If the port is closed, do not restart it yourself — emit `<promise>NEXT</promise>` and let build-ralph.sh retry on the next iteration.

Start the frontend port (`runtime.frontend.port`) yourself only if it is not already open (background, new process group):
  ```bash
  mkdir -p ralph/runtime-logs
  LOG=ralph/runtime-logs/frontend-$(date +%Y%m%d-%H%M%S).log
  <runtime.frontend.devCommand> >"$LOG" 2>&1 &
  echo $! > ralph/runtime-logs/frontend.pid
  disown $! 2>/dev/null || true
  ```
  Wait up to 120 seconds. Expect `curl -fsS <runtime.frontend.previewUrl>` to return 200 or 302.
  On failure, read the last 50 lines of LOG, fix the root cause, and restart.

### 2) Capture error log baseline
Record the backend error log length just before smoke starts, so only **newly added lines** are compared:
```bash
# use runtime.backend.logDir from ralph-config.json
LOG_DIR=$(jq -r '.runtime.backend.logDir' ralph/ralph-config.json)
ERR="${LOG_DIR}/$(date +%F).error.log"
BASE=$(wc -l <"$ERR" 2>/dev/null | tr -d ' ' || echo 0)
```

### 3) Smoke test
Hit 1–2 URLs with `curl -i` (including headers) relevant to the task scope:
- Backend scope: GET endpoint of the controller you changed. 200 or 401 (auth not provided) is acceptable.
- Frontend scope: the route you changed (relative to `runtime.frontend.previewUrl`). 200 or 302 (auth redirect) is acceptable. Follow the project's local auth method if authentication is required.

### 4) Error diff + whitelist
Extract new error lines after the smoke:
```bash
tail -n +"$((BASE+1))" "$ERR"
```
Errors matching regex patterns in `ralph-config.json`'s `runtime.backend.errorLogWhitelist` array are normal noise — ignore them.

If **even one** non-whitelisted ERROR line was added, do not set `build_pass:true`. Trace the root cause and fix it in the same iteration. After changes hot-reload, re-run steps 2)–4). Repeat within the timeout limit. Do not mask errors with try/catch or fallbacks — missing env config (e.g. an absolute URL not set in `.env*`) counts as a root cause and must be fixed.

### 5) Cleanup
- If this iteration started the process, stop it immediately after validation:
  ```bash
  PID=$(cat ralph/runtime-logs/frontend.pid)
  PGID=$(ps -o pgid= -p "$PID" | tr -d ' ')
  kill -- -"$PGID" 2>/dev/null
  rm -f ralph/runtime-logs/frontend.pid
  ```
- If you reused an existing user session, do not kill it.

## After all validations pass
1. Set `build_pass: true` on the target item in `tasks.json`. Do not touch `qa_pass`.
2. (Optional) Append an entry to `qa-hints.json`: `{ "task_id": "...", "tests_written": ["..."], "needs_deeper_qa": ["..."] }` — flag acceptance criteria that automated tests do **not** cover.
3. Append a one-line summary to `build-progress.txt`: `iter <n>: <task_id> [<mode>] — <short summary>`.
4. Stage only the files you actually changed. Avoid `git add -A`, which may pull in unrelated reformatting.
5. `git commit -m "<scope>: <task_id> — <short summary>"` then `git push`.
6. Emit one of:
   - `<promise>NEXT</promise>` — task complete, loop continues.
   - `<promise>COMPLETE</promise>` — all tasks in `tasks.json` are `build_pass:true`.
   - `<promise>BLOCKED</promise>` — see rule above; must surface and stop the loop.

## Output discipline
- One task per iteration. Do not silently batch multiple tasks.
- If the task cannot be finished within the timeout, leave `build_pass:false`, append a progress note explaining where you stopped, leave a WIP commit of partial work, and emit `<promise>NEXT</promise>` so the next iteration can continue.
