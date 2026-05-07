#!/bin/bash
# Phase 2: Build — implement one batch from ralph/tasks.json per iteration
set -euo pipefail

[ -n "${RALPH_INSTALL:-}" ] || RALPH_INSTALL="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "${RALPH_INSTALL}/scripts/ralph-lib.sh"

ITERATIONS="${1:-100}"

[ -f ralph/ralph-config.json ] || { echo "Error: ralph/ralph-config.json not found."; exit 1; }
[ -f ralph/tasks.json ]        || { echo "Error: ralph/tasks.json not found. Run 'ralph plan' first."; exit 1; }
command -v jq >/dev/null    || { echo "Error: jq is required."; exit 1; }

TARGET_NAME=$(jq -r '.projectName' ralph/ralph-config.json)
BUILDER_CMD=$(jq -r '.builder.command' ralph/ralph-config.json)
ITER_TIMEOUT=$(jq -r '.builder.iterationTimeoutSeconds' ralph/ralph-config.json)
BATCH_SIZE="${RALPH_BATCH_SIZE:-$(jq -r '.builder.batchSize // 1' ralph/ralph-config.json)}"
RUNTIME_SMOKE=$(jq -r '.validation.runtimeSmoke // "perTask"' ralph/ralph-config.json)
BACKEND_PORT=$(jq -r '.runtime.backend.port // empty' ralph/ralph-config.json)
BACKEND_DEV_CMD=$(jq -r '.runtime.backend.devCommand // empty' ralph/ralph-config.json)
require_agent_command "$BUILDER_CMD" "builder.command"

echo "=== ${TARGET_NAME} ralph: Phase 2 (Build) ==="
echo "Iterations: $ITERATIONS"
echo "Batch size: $BATCH_SIZE"
echo ""

touch ralph/build-progress.txt
[ -f ralph/qa-report.json ] || echo '[]' > ralph/qa-report.json
[ -f ralph/qa-hints.json ]  || echo '[]' > ralph/qa-hints.json

BACKEND_LOG_DIR="ralph/runtime-logs"

_backend_responsive() {
  [ -z "$BACKEND_PORT" ] && return 1
  local status
  status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "http://localhost:${BACKEND_PORT}/" 2>/dev/null || echo "000")
  [ "$status" != "000" ]
}

ensure_backend_healthy() {
  [ "$RUNTIME_SMOKE" = "final" ] && return 0
  [ -z "$BACKEND_PORT" ] && return 0
  [ -z "$BACKEND_DEV_CMD" ] && return 0

  local scope
  scope=$(jq -r '[.[] | select(.build_pass==false)] | first | .scope // ""' ralph/tasks.json 2>/dev/null || echo "")
  local needs_backend
  needs_backend=$(jq -r --arg s "$scope" '(.runtime.backend.affectedScopes // []) | index($s) != null | tostring' ralph/ralph-config.json 2>/dev/null || echo "false")
  [ "$needs_backend" = "true" ] || return 0

  local pid
  pid=$(lsof -iTCP:${BACKEND_PORT} -sTCP:LISTEN -t 2>/dev/null | head -1 || true)

  if [ -n "$pid" ]; then
    if _backend_responsive; then
      return 0
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

get_task_batch() {
  jq -rn --argjson limit "$BATCH_SIZE" --slurpfile tasks ralph/tasks.json '
    ($tasks[0]) as $tasks
    | ($tasks | map(select(.build_pass != true))) as $pending
    | def dep_passed($dep): any($tasks[]; .id == $dep and .build_pass == true);
    | if ($pending | length) == 0 then
        {status: "complete", tasks: []}
      else
        ($pending[0]) as $first
        | if ((($first.dependent_on // []) | all(dep_passed(.))) | not) then
            {status: "blocked", blocked_task: $first}
          else
            {
              status: "ready",
              tasks: ([
                $pending[]
                | select(.scope == $first.scope)
                | select((.dependent_on // []) | all(dep_passed(.)))
              ] | .[0:$limit])
            }
          end
      end
  '
}

get_qa_context() {
  local batch_json="$1"
  jq -rn --argjson batch "$batch_json" --slurpfile report ralph/qa-report.json '
    ($batch | map(.id)) as $ids
    | ($report[0] | map(select(.task_id as $tid | $ids | index($tid)))) as $fails
    | if ($fails | length) == 0 then ""
      else
        "=== QA FAILURE CONTEXT FOR BATCH ===\n" +
        ($fails | map(
          "Task: " + (.task_id // "unknown") + "\n" +
          "Attempt: " + ((.attempt // 0) | tostring) + "\n" +
          "Status: " + (.status // "unknown") + "\n" +
          "Bugs:\n" + ((.bugs_found // []) | map(
            "  - [" + (.severity // "?") + "] " + (.description // (. | tostring))
            + (if .file then "\n    File: " + .file else "" end)
            + (if .steps_to_reproduce then "\n    Steps to reproduce: " + .steps_to_reproduce else "" end)
          ) | join("\n")) + "\n" +
          "Tested steps:\n" + ((.tested_steps // []) | map("  - " + .) | join("\n")) + "\n"
        ) | join("\n---\n"))
      end
  ' 2>/dev/null || echo ""
}

get_downstream_context() {
  local batch_json="$1"
  jq -rn --argjson batch "$batch_json" --slurpfile tasks ralph/tasks.json '
    ($tasks[0]) as $prd
    | ($batch | map(.id)) as $ids
    | "Batch dependencies:\n" +
      (($batch | map((.id // "?") + " depends on " + (((.dependent_on // []) | join(", ")) // ""))) | map("  - " + .) | join("\n")) +
      "\nDownstream tasks:\n" +
      (($prd | map(select((.dependent_on // []) | any(. as $dep | $ids | index($dep))) | "  - " + .id)) | join("\n"))
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

  BUNDLE=$(get_task_batch)
  BUNDLE_STATUS=$(printf '%s' "$BUNDLE" | jq -r '.status')

  if [ "$BUNDLE_STATUS" = "complete" ]; then
    echo "All $TOTAL tasks already build_pass!"
    exit 0
  fi

  if [ "$BUNDLE_STATUS" = "blocked" ]; then
    echo ""
    echo "=== Build BLOCKED — task with unsatisfied dependencies. ==="
    printf '%s\n' "$BUNDLE" | jq '.blocked_task'
    exit 2
  fi

  TASK_BATCH=$(printf '%s' "$BUNDLE" | jq '.tasks')
  BATCH_COUNT=$(printf '%s' "$TASK_BATCH" | jq 'length')
  BATCH_SCOPE=$(printf '%s' "$TASK_BATCH" | jq -r '.[0].scope // "unknown"')
  DOWNSTREAM_CONTEXT=$(get_downstream_context "$TASK_BATCH")
  QA_CONTEXT=$(get_qa_context "$TASK_BATCH")

  echo "  -> Task batch: $BATCH_COUNT task(s), scope=$BATCH_SCOPE"

  if [ -n "$QA_CONTEXT" ]; then
    echo "  -> Rebuild mode: QA failure detected, providing root-cause context"
    MODE_SECTION="MODE: REBUILD — One or more tasks in this batch failed previous QA. Read the failure context carefully.

$QA_CONTEXT

$DOWNSTREAM_CONTEXT

REBUILD instructions:
1. Read the QA failure context above — understand exactly what broke and how.
2. Trace the root cause — read all related source files, not just where the bug surfaced.
3. Check dependent tasks — bugs in dependencies have cascading effects.
4. Check downstream tasks — make sure the fix does not break them.
5. Fix the root cause, not the symptom.
6. Update tests to explicitly cover the failure scenarios from the QA report.
7. Run the configured quick validation for the batch scope — it must exit 0.
8. Set build_pass:true only for tasks completed in this batch, commit, push."
  else
    MODE_SECTION="Build this task batch in order. Complete only the tasks listed in TASK_BATCH, then commit, push, and stop.

$DOWNSTREAM_CONTEXT"
  fi

  result=$(timeout "$ITER_TIMEOUT" $BUILDER_CMD \
"@${RALPH_INSTALL}/prompts/build-prompt.md @ralph/ralph-config.json @ralph/tasks.json @ralph/build-progress.txt @ralph/qa-report.json @ralph/qa-hints.json

ITERATION: $i of $ITERATIONS
PROGRESS: $PASSES/$TOTAL tasks build_pass
BATCH_SIZE: $BATCH_SIZE
TASK_BATCH:
$TASK_BATCH

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
