#!/bin/bash
# Phase 3: QA — independent evaluator validates one task per iteration.
set -euo pipefail

[ -n "${RALPH_INSTALL:-}" ] || RALPH_INSTALL="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "${RALPH_INSTALL}/scripts/ralph-lib.sh"

ITERATIONS="${1:-100}"

[ -f ralph/ralph-config.json ] || { echo "Error: ralph/ralph-config.json not found."; exit 1; }
[ -f ralph/tasks.json ]        || { echo "Error: ralph/tasks.json not found."; exit 1; }
command -v jq >/dev/null    || { echo "Error: jq is required."; exit 1; }

TARGET_NAME=$(jq -r '.projectName' ralph/ralph-config.json)
EVAL_CMD=$(jq -r '.evaluator.command' ralph/ralph-config.json)
EVAL_TIMEOUT=$(jq -r '.evaluator.iterationTimeoutSeconds // 1800' ralph/ralph-config.json)
MAX_RETRIES=$(jq -r '.evaluator.maxRetries' ralph/ralph-config.json)
DEV_CMD=$(jq -r '.runtime.frontend.devCommand // empty' ralph/ralph-config.json)
PREVIEW_URL=$(jq -r '.runtime.frontend.previewUrl // empty' ralph/ralph-config.json)
require_agent_command "$EVAL_CMD" "evaluator.command"

[ -f ralph/qa-report.json ] || echo '[]' > ralph/qa-report.json
[ -f ralph/qa-hints.json ]  || echo '[]' > ralph/qa-hints.json

echo "=== ${TARGET_NAME} ralph: Phase 3 (QA) ==="
echo "Evaluator: $EVAL_CMD"
echo "Max retries per task: $MAX_RETRIES"
echo ""

DEV_PID=""
DEV_RUNNING="false"
start_dev_if_needed() {
  local kind="$1"
  if [ "$kind" = "frontend" ] && [ "$DEV_RUNNING" = "false" ] && [ -n "$DEV_CMD" ]; then
    echo "Starting dev server: $DEV_CMD"
    bash -c "$DEV_CMD" &
    DEV_PID=$!
    DEV_RUNNING="true"
    sleep 8
  fi
}
trap '[ -n "$DEV_PID" ] && kill $DEV_PID 2>/dev/null || true' EXIT

get_next_task() {
  jq -rn --slurpfile t ralph/tasks.json --slurpfile r ralph/qa-report.json --argjson cap "$MAX_RETRIES" '
    ($t[0]) as $tasks
    | ($r[0]) as $report
    | ($tasks | map(. + {_attempts: ([$report[] | select(.task_id == .id)] | length)}) | map(select(.qa_pass != true and ._attempts < $cap)) | first) as $next
    | if $next == null then "ALL_DONE"
      else
        {main: $next,
         attempts: $next._attempts,
         dependencies: [$tasks[] as $t | $next.dependent_on // [] | if index($t.id) then $t else empty end]}
        | tojson
      end
  ' 2>/dev/null
}

for ((i=1; i<=$ITERATIONS; i++)); do
  TOTAL=$(total_tasks)
  PASSED=$(qa_passed)
  echo "--- QA iteration $i ($PASSED/$TOTAL qa_pass) ---"

  BUNDLE=$(get_next_task)
  if [ "$BUNDLE" = "ALL_DONE" ] || [ -z "$BUNDLE" ]; then
    echo "All tasks are qa_pass:true or retry limit exhausted."
    break
  fi

  TASK_FILE="ralph/.current-task-$$.json"
  echo "$BUNDLE" > "$TASK_FILE"

  TASK_ID=$(jq -r '.main.id'      "$TASK_FILE")
  KIND=$(jq    -r '.main.kind'    "$TASK_FILE")
  ATTEMPT=$(jq -r '.attempts + 1' "$TASK_FILE")
  echo "Testing: $TASK_ID ($KIND) — attempt $ATTEMPT/$MAX_RETRIES"

  start_dev_if_needed "$KIND"

  HINTS=$(jq -r --arg id "$TASK_ID" '
    [.[] | select(.task_id == $id)] |
    if length == 0 then "No QA hints from build agent for this task."
    else map("Tests written: " + ((.tests_written // []) | join(", ")) + "\nAreas needing deeper QA:\n" + ((.needs_deeper_qa // []) | map("  - " + .) | join("\n"))) | join("\n---\n")
    end
  ' ralph/qa-hints.json)

  HISTORY=$(jq -r --arg id "$TASK_ID" '
    [.[] | select(.task_id == $id)] |
    if length == 0 then "No previous attempts." else
      map("Attempt " + ((.attempt // 0) | tostring) + ": status=" + (.status // "?") + ", fix applied: " + (.fix_description // "no description") +
          "\n  Bugs:\n" + ((.bugs_found // []) | map("    - [" + (.severity // "?") + "] " + (.description // (.|tostring))) | join("\n"))) | join("\n\n")
    end
  ' ralph/qa-report.json)

  MAIN_TASK=$(jq '.main' "$TASK_FILE")
  DEPS=$(jq -r '.dependencies | if length == 0 then "No dependencies." else map("- " + .id + ": " + (.description // "")[0:100]) | join("\n") end' "$TASK_FILE")

  PREVIEW_NOTE=""
  if [ "$KIND" = "frontend" ] && [ -n "$PREVIEW_URL" ]; then
    PREVIEW_NOTE="DEV SERVER: running at $PREVIEW_URL — use the browser agent for manual smoke testing."
  fi

  result=$(timeout "$EVAL_TIMEOUT" $EVAL_CMD \
"$(cat "${RALPH_INSTALL}/prompts/qa-prompt.md")

== FEATURE TO TEST ==
$MAIN_TASK

== RELATED FEATURES (dependencies for context) ==
$DEPS

== BUILD AGENT QA HINTS ==
$HINTS

== QA HISTORY FOR THIS FEATURE (ALL PREVIOUS ATTEMPTS) ==
$HISTORY

Read the following files as needed:
@ralph/ralph-config.json
@ralph/tasks.json
@ralph/qa-report.json

QA progress: $PASSED/$TOTAL features done
TASK: $TASK_ID (kind: $KIND)
ATTEMPT: $ATTEMPT of $MAX_RETRIES
$PREVIEW_NOTE

Test this ONE task thoroughly. Review the QA history above — if previous attempts failed, try a different angle.
Then do the following:
1. Append a NEW entry to ralph/qa-report.json with attempt: $ATTEMPT (do not overwrite previous entries).
2. Fix any bugs found within the allowed scope.
3. Set qa_pass:true in ralph/tasks.json only when all acceptance criteria are verified and all validation commands exit 0; otherwise leave qa_pass:false.
4. Run the validation commands from ralph-config.json for the task scope. All must exit 0 before setting qa_pass:true.
5. git add the changed files, commit (qa: <task_id> attempt <n> — pass|fail|partial), git push.
6. Output <promise>NEXT</promise> when done.")

  echo "$result"
  rm -f "$TASK_FILE"

  if [[ "$result" == *"<promise>NEXT</promise>"* ]]; then
    echo "QA attempt $ATTEMPT for ${TASK_ID} complete."
    continue
  fi

  echo "Warning: no promise received from evaluator for $TASK_ID (attempt $ATTEMPT). Recording as partial..."
  jq --arg id "$TASK_ID" --argjson att "$ATTEMPT" '
    . + [{task_id: $id, attempt: $att, status: "partial", tested_steps: ["Evaluator crashed or timed out"], bugs_found: [], fix_description: "Evaluator did not complete"}]
  ' ralph/qa-report.json > ralph/qa-report.json.tmp && mv ralph/qa-report.json.tmp ralph/qa-report.json
  sleep 3
done

PASSED=$(qa_passed); TOTAL=$(total_tasks)
echo ""
echo "=== QA ended: $PASSED/$TOTAL tasks qa_pass ==="
echo "Check ralph/qa-report.json for the full attempt history."
