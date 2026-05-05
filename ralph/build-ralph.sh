#!/bin/bash
# Phase 2: Build — implement one item from ralph/tasks.json per iteration
# Enforced by prompt and NEXT/COMPLETE/BLOCKED promises
set -euo pipefail
cd "$(dirname "$0")/.."
source ralph/ralph-lib.sh

ITERATIONS="${1:-100}"

[ -f ralph/ralph-config.json ] || { echo "Error: ralph/ralph-config.json not found."; exit 1; }
[ -f ralph/tasks.json ] || { echo "Error: ralph/tasks.json not found. Run plan-ralph.sh first."; exit 1; }
command -v jq >/dev/null || { echo "Error: jq is required."; exit 1; }
command -v claude >/dev/null || { echo "Error: claude CLI not found in PATH."; exit 1; }

TARGET_NAME=$(jq -r '.projectName' ralph/ralph-config.json)
BUILDER_CMD=$(jq -r '.builder.command' ralph/ralph-config.json)
ITER_TIMEOUT=$(jq -r '.builder.iterationTimeoutSeconds' ralph/ralph-config.json)
BACKEND_PORT=$(jq -r '.runtime.backend.port // empty' ralph/ralph-config.json)
BACKEND_DEV_CMD=$(jq -r '.runtime.backend.devCommand // empty' ralph/ralph-config.json)

echo "=== ${TARGET_NAME} ralph: Phase 2 (Build) ==="
echo "Iterations: $ITERATIONS"
echo ""

touch ralph/build-progress.txt
[ -f ralph/qa-report.json ] || echo '[]' > ralph/qa-report.json
[ -f ralph/qa-hints.json ]  || echo '[]' > ralph/qa-hints.json

# ── Backend auto-restart ──────────────────────────────────────────────────────
BACKEND_LOG_DIR="ralph/runtime-logs"

_backend_responsive() {
  [ -z "$BACKEND_PORT" ] && return 1
  local status
  status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "http://localhost:${BACKEND_PORT}/" 2>/dev/null || echo "000")
  [ "$status" != "000" ]
}

ensure_backend_healthy() {
  # Skip if backend.port or backend.devCommand is not configured
  [ -z "$BACKEND_PORT" ] && return 0
  [ -z "$BACKEND_DEV_CMD" ] && return 0

  # Skip if the next target task's scope is not in backend.scopes
  local scope
  scope=$(jq -r '[.[] | select(.build_pass==false)] | first | .scope // ""' ralph/tasks.json 2>/dev/null || echo "")
  local needs_backend
  needs_backend=$(jq -r --arg s "$scope" '(.runtime.backend.affectedScopes // []) | index($s) != null | tostring' ralph/ralph-config.json 2>/dev/null || echo "false")
  [ "$needs_backend" = "true" ] || return 0

  local pid
  pid=$(lsof -iTCP:${BACKEND_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1 || true)

  if [ -n "$pid" ]; then
    if _backend_responsive; then
      return 0  # healthy
    fi
    echo "[backend-health] Port ${BACKEND_PORT} is LISTEN but HTTP unresponsive (PID $pid) — auto-restarting"
    kill -9 "$pid" 2>/dev/null || true
    sleep 2
  else
    echo "[backend-health] Port ${BACKEND_PORT} not running — starting backend"
  fi

  mkdir -p "$BACKEND_LOG_DIR"
  local log="${BACKEND_LOG_DIR}/backend-$(date +%Y%m%d-%H%M%S).log"
  $BACKEND_DEV_CMD >"$log" 2>&1 &
  local new_pid=$!
  disown "$new_pid" 2>/dev/null || true
  echo "$new_pid" > "${BACKEND_LOG_DIR}/backend.pid"
  echo "[backend-health] Backend starting (PID $new_pid, log: $log)"

  local waited=0
  while [ $waited -lt 120 ]; do
    sleep 5
    waited=$((waited + 5))
    if _backend_responsive; then
      echo "[backend-health] Backend ready (${waited}s)"
      return 0
    fi
  done

  echo "[backend-health] Backend unresponsive after 120s — last 20 lines of log:"
  tail -20 "$log" 2>/dev/null || true
  return 1
}
# ────────────────────────────────────────────────────────────────────────────

# Build a "QA failure context" block if the next target task has previous failed attempts
get_qa_context() {
  jq -rn --slurpfile tasks ralph/tasks.json --slurpfile report ralph/qa-report.json '
    ($tasks[0]) as $prd
    | ($prd | map(select(.build_pass==false)) | first) as $target
    | if $target == null then ""
      else
        ($target.id) as $tid
        | ($report[0] | map(select(.task_id == $tid))) as $fails
        | if ($fails | length) == 0 then ""
          else
            "=== QA FAILURE CONTEXT FOR " + $tid + " ===\n" +
            "This task was previously BUILT but failed QA " + ($fails | length | tostring) + " time(s).\n" +
            "Analyze the root cause — do not just patch symptoms.\n\n" +
            ($fails | map(
              "--- QA Attempt " + ((.attempt // 0) | tostring) + " ---\n" +
              "Status: " + (.status // "unknown") + "\n" +
              "Bugs:\n" + ((.bugs_found // []) | map(
                "  - [" + (.severity // "?") + "] " + (.description // (. | tostring))
                + (if .file then "\n    File: " + .file else "" end)
                + (if .steps_to_reproduce then "\n    Steps to reproduce: " + .steps_to_reproduce else "" end)
              ) | join("\n")) + "\n" +
              "Tested steps:\n" + ((.tested_steps // []) | map("  - " + .) | join("\n")) + "\n"
            ) | join("\n")) +
            "\nDependent tasks (read together for common root cause):\n" +
            (($target.dependent_on // []) | map("  - " + .) | join("\n")) + "\n" +
            "Downstream tasks (depend on this task — fix may affect them):\n" +
            (($prd | map(select((.dependent_on // []) | index($tid)) | "  - " + .id)) | join("\n")) + "\n"
          end
      end
  ' 2>/dev/null || echo ""
}

for ((i=1; i<=$ITERATIONS; i++)); do
  PASSES=$(count_passes)
  TOTAL=$(total_tasks)
  echo "--- Build iteration $i/$ITERATIONS ($PASSES/$TOTAL build_pass) ---"

  if [ "$PASSES" -ge "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
    echo "All $TOTAL tasks already build_pass!"
    exit 0
  fi

  ensure_backend_healthy || { echo "[backend-health] Backend failed to start — skipping iteration $i"; sleep 10; continue; }

  QA_CONTEXT=$(get_qa_context)

  if [ -n "$QA_CONTEXT" ]; then
    echo "  -> Rebuild mode: QA failure detected, providing root-cause context"
    MODE_SECTION="MODE: REBUILD — This task failed a previous QA. Read the failure context below carefully.

$QA_CONTEXT

REBUILD instructions:
1. Read the QA failure context above — understand exactly what broke and how.
2. Trace the root cause — read all related source files, not just where the bug surfaced. The real bug is usually in packages/* utilities or shared types.
3. Check dependent tasks — bugs in dependencies have cascading effects.
4. Check downstream tasks — make sure the fix does not break them.
5. If the bug stems from a structural issue, consider refactoring. A targeted refactor that catches the root cause is better than a narrow patch that fails QA again.
6. Fix the root cause, not the symptom.
7. Update tests to explicitly cover the failure scenarios from the QA report.
8. Run lint + typecheck + test with turbo --filter for the task scope — all must exit 0.
9. Set build_pass:true, commit, push."
  else
    MODE_SECTION="Build exactly ONE task (the first build_pass:false item). Then commit, push, and stop."
  fi

  result=$(timeout "$ITER_TIMEOUT" $BUILDER_CMD \
"@ralph/build-prompt.md @ralph/ralph-config.json @ralph/tasks.json @ralph/build-progress.txt @ralph/qa-report.json @ralph/qa-hints.json

ITERATION: $i of $ITERATIONS
PROGRESS: $PASSES/$TOTAL tasks build_pass

$MODE_SECTION

Output <promise>NEXT</promise> when done.
Output <promise>COMPLETE</promise> only when all tasks are build_pass.
Output <promise>BLOCKED</promise> if dependencies are not satisfied.")

  echo "$result"

  if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
    echo ""
    echo "=== Build complete after $i iteration(s)! All $(total_tasks) tasks passed. ==="
    exit 0
  fi

  if [[ "$result" == *"<promise>BLOCKED</promise>"* ]]; then
    echo ""
    echo "=== Build BLOCKED — task with unsatisfied dependencies. Check ralph/tasks.json. ==="
    exit 2
  fi

  if [[ "$result" == *"<promise>NEXT</promise>"* ]]; then
    echo "Task complete. Continuing..."
    continue
  fi

  echo "Warning: no promise found. Agent may have crashed or hit context limit. Restarting..."
  sleep 3
done

echo ""
echo "=== Build ended after $ITERATIONS iterations ==="
echo "Passed: $(count_passes)/$(total_tasks). Check ralph/tasks.json for remaining items."
