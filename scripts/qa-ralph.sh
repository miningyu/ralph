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
    | def spec_key($task): {
        id: $task.id,
        scope: $task.scope,
        path: $task.path,
        kind: $task.kind,
        description: $task.description,
        acceptance: ($task.acceptance // []),
        dependent_on: ($task.dependent_on // []),
        touches: ($task.touches // [])
      } | @json;
    def task_attempts($task): (spec_key($task)) as $key | [$report[] | select(.task_id == $task.id and (.task_spec_key // "") == $key)] | length;
    ($tasks
       | map(. as $task | $task + {_attempts: task_attempts($task), _spec_key: spec_key($task)})
       | map(select(.qa_pass != true))
       | map(select((.qa_status // "") as $s | ($s == "blocked" or $s == "infra_blocked") | not))
      ) as $pending
    | ($pending | map(select(._attempts < $cap)) | first) as $next
    | if $next == null then
        if ($pending | length) == 0 then "ALL_DONE" else "RETRY_EXHAUSTED" end
      else
        {main: $next,
         attempts: $next._attempts,
         task_spec_key: $next._spec_key,
         dependencies: [$tasks[] as $t | $next.dependent_on // [] | if index($t.id) then $t else empty end]}
        | tojson
      end
  ' 2>/dev/null
}

mark_retry_exhausted() {
  jq --slurpfile r ralph/qa-report.json --argjson cap "$MAX_RETRIES" '
    ($r[0]) as $report
    | def spec_key($task): {
        id: $task.id,
        scope: $task.scope,
        path: $task.path,
        kind: $task.kind,
        description: $task.description,
        acceptance: ($task.acceptance // []),
        dependent_on: ($task.dependent_on // []),
        touches: ($task.touches // [])
      } | @json;
    def task_attempts($task): (spec_key($task)) as $key | [$report[] | select(.task_id == $task.id and (.task_spec_key // "") == $key)] | length;
    map(
        if .qa_pass != true
           and (((.qa_status // "") as $s | $s == "blocked" or $s == "infra_blocked") | not)
           and (task_attempts(.) >= $cap)
        then . + {
          qa_status: "blocked",
          qa_blocked_reason: ("retry limit exhausted (" + ((task_attempts(.)) | tostring) + "/" + ($cap | tostring) + ")")
        }
        else .
        end
      )
  ' ralph/tasks.json > ralph/tasks.json.tmp && mv ralph/tasks.json.tmp ralph/tasks.json
}

stamp_report_entries() {
  local task_id="$1"
  local attempt="$2"
  local task_spec_key="$3"
  local git_sha="${4:-$(git rev-parse HEAD 2>/dev/null || echo "")}"

  jq --arg id "$task_id" --argjson att "$attempt" --arg key "$task_spec_key" --arg sha "$git_sha" '
    map(
      if .task_id == $id and (.attempt // 0) == $att
      then . + (if (.task_spec_key // "") == "" then {task_spec_key: $key} else {} end)
             + (if (.git_sha // "") == "" then {git_sha: $sha} else {} end)
      else .
      end
    )
  ' ralph/qa-report.json > ralph/qa-report.json.tmp && mv ralph/qa-report.json.tmp ralph/qa-report.json
}

# ── No-op skip ────────────────────────────────────────────────────────────────
# If a task previously passed and no file in its path∪touches has changed since,
# skip the LLM agent and mark qa_pass:true directly. Catches re-runs after
# rebases / partial resets where the build batch didn't actually move task files.
no_op_skip_applies() {
  local task_id="$1" task_spec_key="$2"
  local last_sha changed
  last_sha=$(last_pass_sha_for_task "$task_id" "$task_spec_key")
  [ -n "$last_sha" ] || return 1
  changed=$(task_files_changed_since "$task_id" "$last_sha")
  [ -z "$changed" ] && return 0
  return 1
}

mark_task_qa_pass() {
  local task_id="$1"
  jq --arg id "$task_id" '
    map(if .id == $id then . + {qa_pass: true} else . end)
  ' ralph/tasks.json > ralph/tasks.json.tmp && mv ralph/tasks.json.tmp ralph/tasks.json
}

mark_task_qa_fail() {
  local task_id="$1"
  jq --arg id "$task_id" '
    map(if .id == $id then . + {qa_pass: false} else . end)
  ' ralph/tasks.json > ralph/tasks.json.tmp && mv ralph/tasks.json.tmp ralph/tasks.json
}

append_no_op_report() {
  local task_id="$1" attempt="$2" task_spec_key="$3"
  local sha="$(git rev-parse HEAD 2>/dev/null || echo "")"
  jq --arg id "$task_id" --argjson att "$attempt" --arg key "$task_spec_key" --arg sha "$sha" '
    . + [{
      task_id: $id,
      attempt: $att,
      task_spec_key: $key,
      git_sha: $sha,
      status: "pass",
      tested_steps: ["No-op skip: files in path∪touches unchanged since last green QA"],
      bugs_found: [],
      fix_description: "Orchestrator-level skip; no LLM evaluator invoked"
    }]
  ' ralph/qa-report.json > ralph/qa-report.json.tmp && mv ralph/qa-report.json.tmp ralph/qa-report.json
}

# ── Deterministic pre/post validation ─────────────────────────────────────────
# Run lint/typecheck/test/testE2E for the task scope outside the LLM. Cached
# results short-circuit. Output is a markdown block injected into the prompt as
# == DETERMINISTIC VALIDATION ==.
run_one_validation() {
  # args: scope, name. Echos one or more lines describing the result.
  local scope="$1" name="$2"
  local cfg=ralph/ralph-config.json
  local template
  template=$(jq -r --arg n "$name" '.commands[$n] // empty' "$cfg" 2>/dev/null)
  if [ -z "$template" ]; then
    echo "- ${name}: skipped (commands.${name} not configured)"
    return 0
  fi

  local cached
  cached=$(qa_cache_lookup "$scope" "$name")
  if [ "$cached" = "0" ]; then
    echo "- ${name}: PASS (cached)"
    return 0
  fi

  local cmd="${template//\{scope\}/$scope}"
  local log_dir="ralph/.qa-cache/_logs"
  mkdir -p "$log_dir"
  local log_file="${log_dir}/${scope}-${name}-$(date +%s).log"
  echo "Running pre-QA ${name}: $cmd" >&2
  local exit_code=0
  bash -lc "$cmd" >"$log_file" 2>&1 || exit_code=$?
  qa_cache_save "$scope" "$name" "$exit_code" "$log_file"
  if [ "$exit_code" -eq 0 ]; then
    echo "- ${name}: PASS"
  else
    echo "- ${name}: FAIL (exit=${exit_code})"
    echo "  log: ${log_file}"
    echo "  tail:"
    tail -n 40 "$log_file" 2>/dev/null | sed 's/^/    /'
  fi
}

run_validation_block() {
  # args: scope, has_e2e ("true"/"false")
  local scope="$1" has_e2e="$2"
  if [ -z "$scope" ]; then
    echo "Scope: <unset>; skipping deterministic validation."
    return 0
  fi
  echo "Scope: ${scope}"
  run_one_validation "$scope" "lint"
  run_one_validation "$scope" "typecheck"
  run_one_validation "$scope" "test"
  if [ "$has_e2e" = "true" ]; then
    run_one_validation "$scope" "testE2E"
  fi
}

validation_block_failed() {
  # Returns 0 if any "FAIL" line is present
  printf '%s' "$1" | grep -q "^- .*: FAIL"
}

scope_has_e2e() {
  local scope="$1"
  [ -n "$scope" ] || { echo "false"; return; }
  jq -r --arg s "$scope" '
    [.workspaces.apps[]?, .workspaces.packages[]?]
    | map(select(.name == $s)) | first | (.hasE2E // false) | tostring
  ' ralph/ralph-config.json 2>/dev/null || echo "false"
}

for ((i=1; i<=$ITERATIONS; i++)); do
  TOTAL=$(total_tasks)
  PASSED=$(qa_passed)
  echo "--- QA iteration $i ($PASSED/$TOTAL qa_pass) ---"

  BUNDLE=$(get_next_task)
  if [ "$BUNDLE" = "RETRY_EXHAUSTED" ]; then
    echo "QA retry limit exhausted for at least one task. Marking unresolved tasks as qa_status:blocked."
    mark_retry_exhausted
    break
  fi

  if [ "$BUNDLE" = "ALL_DONE" ] || [ -z "$BUNDLE" ]; then
    echo "All tasks are qa_pass:true, blocked, or infra_blocked."
    break
  fi

  TASK_FILE="ralph/.current-task-$$.json"
  echo "$BUNDLE" > "$TASK_FILE"

  TASK_ID=$(jq -r '.main.id'      "$TASK_FILE")
  KIND=$(jq    -r '.main.kind'    "$TASK_FILE")
  SCOPE=$(jq   -r '.main.scope // ""' "$TASK_FILE")
  ATTEMPT=$(jq -r '.attempts + 1' "$TASK_FILE")
  TASK_SPEC_KEY=$(jq -r '.task_spec_key' "$TASK_FILE")
  echo "Testing: $TASK_ID ($KIND) — attempt $ATTEMPT/$MAX_RETRIES"

  # 1. No-op skip: previously-passing task with no source changes
  if no_op_skip_applies "$TASK_ID" "$TASK_SPEC_KEY"; then
    echo "Task ${TASK_ID}: files in path∪touches unchanged since last green QA. Marking qa_pass:true (no LLM call)."
    mark_task_qa_pass "$TASK_ID"
    append_no_op_report "$TASK_ID" "$ATTEMPT" "$TASK_SPEC_KEY"
    rm -f "$TASK_FILE"
    continue
  fi

  start_dev_if_needed "$KIND"

  # 2. Deterministic pre-validation: run lint/typecheck/test outside the LLM
  HAS_E2E=$(scope_has_e2e "$SCOPE")
  echo "Running deterministic validation for scope=${SCOPE} (hasE2E=${HAS_E2E})..."
  PRE_VALIDATION=$(run_validation_block "$SCOPE" "$HAS_E2E")
  if validation_block_failed "$PRE_VALIDATION"; then
    PRE_VALIDATION_STATUS="some commands FAILED — see log_tail below; LLM should focus on root-cause fixes"
  else
    PRE_VALIDATION_STATUS="all configured commands PASSED — LLM should focus on acceptance + static review only"
  fi
  KIND_TIMEOUT=$(per_kind_timeout "$KIND")

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

  result=$(timeout "$KIND_TIMEOUT" $EVAL_CMD \
"$(cat "${RALPH_INSTALL}/prompts/qa-prompt.md")

== FEATURE TO TEST ==
$MAIN_TASK

== RELATED FEATURES (dependencies for context) ==
$DEPS

== BUILD AGENT QA HINTS ==
$HINTS

== QA HISTORY FOR THIS FEATURE (ALL PREVIOUS ATTEMPTS) ==
$HISTORY

== DETERMINISTIC VALIDATION (pre-run by orchestrator; ${PRE_VALIDATION_STATUS}) ==
$PRE_VALIDATION

Read the following files as needed:
@ralph/ralph-config.json
@ralph/tasks.json
@ralph/qa-report.json

QA progress: $PASSED/$TOTAL features done
TASK: $TASK_ID (kind: $KIND, scope: $SCOPE)
ATTEMPT: $ATTEMPT of $MAX_RETRIES
TIMEOUT: ${KIND_TIMEOUT}s
TASK_SPEC_KEY: $TASK_SPEC_KEY
$PREVIEW_NOTE

Test this ONE task thoroughly. Review the QA history above — if previous attempts failed, try a different angle.
Then do the following:
1. Append a NEW entry to ralph/qa-report.json with attempt: $ATTEMPT and task_spec_key: \"$TASK_SPEC_KEY\" (do not overwrite previous entries). The orchestrator stamps git_sha automatically — do not set it yourself.
2. Fix any bugs found within the allowed scope.
3. Set qa_pass:true in ralph/tasks.json only when all acceptance criteria are verified AND every command in == DETERMINISTIC VALIDATION == is PASS (or PASS (cached)). Do not re-run a command shown as PASS.
4. If a command in == DETERMINISTIC VALIDATION == is FAIL, fix the root cause and re-run only that command (the orchestrator caches and re-checks afterward; the cache invalidates automatically when the relevant files change). If a command has a documented baseline failure, record the baseline comparison in your report rather than blaming the task.
5. If validation is blocked by missing local infrastructure (browser agent unavailable, required dev server unavailable, credentials missing), set qa_status:\"infra_blocked\" for this task and describe the missing prerequisite.
6. Do not modify task spec fields in ralph/tasks.json during QA: id, scope, path, description, acceptance, context, dependent_on, and touches are immutable after plan completion. If acceptance conflicts with current code or later tasks, leave qa_pass:false and set qa_status:\"blocked\" with qa_blocked_reason instead of changing the acceptance.
7. Commit and push only pass results, direct code fixes, or qa_status transitions such as blocked/infra_blocked. Do not commit repeated fail-only qa-report entries. The orchestrator may add an additional override commit afterward if its post-iteration recheck disagrees with your qa_pass — do not pre-empt that.
8. Output <promise>NEXT</promise> when done.")

  echo "$result"
  POST_HEAD_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
  stamp_report_entries "$TASK_ID" "$ATTEMPT" "$TASK_SPEC_KEY" "$POST_HEAD_SHA"
  rm -f "$TASK_FILE"

  # 3. Post-LLM recheck — if the LLM committed and claimed pass, re-validate to
  #    catch the "evaluator rationalized a fail as pass" failure mode. Cached
  #    results are reused for unchanged scopes, so this is cheap when nothing
  #    moved.
  if [ -n "$SCOPE" ]; then
    POST_VALIDATION=$(run_validation_block "$SCOPE" "$HAS_E2E")
    if validation_block_failed "$POST_VALIDATION"; then
      CURRENT_PASS=$(jq -r --arg id "$TASK_ID" '[.[] | select(.id == $id)] | first | .qa_pass // false' ralph/tasks.json 2>/dev/null || echo "false")
      if [ "$CURRENT_PASS" = "true" ]; then
        echo "Post-recheck: $TASK_ID validation FAILED after LLM run; forcing qa_pass:false."
        echo "$POST_VALIDATION" | sed 's/^/  /'
        mark_task_qa_fail "$TASK_ID"
      fi
    fi
  fi

  if [[ "$result" == *"<promise>NEXT</promise>"* ]]; then
    echo "QA attempt $ATTEMPT for ${TASK_ID} complete."
    continue
  fi

  echo "Warning: no promise received from evaluator for $TASK_ID (attempt $ATTEMPT). Recording as partial..."
  jq --arg id "$TASK_ID" --argjson att "$ATTEMPT" '
    . + [{task_id: $id, attempt: $att, status: "partial", tested_steps: ["Evaluator crashed or timed out"], bugs_found: [], fix_description: "Evaluator did not complete"}]
  ' ralph/qa-report.json > ralph/qa-report.json.tmp && mv ralph/qa-report.json.tmp ralph/qa-report.json
  stamp_report_entries "$TASK_ID" "$ATTEMPT" "$TASK_SPEC_KEY" "$(git rev-parse HEAD 2>/dev/null || echo '')"
  sleep 3
done

PASSED=$(qa_passed); TOTAL=$(total_tasks)
echo ""
echo "=== QA ended: $PASSED/$TOTAL tasks qa_pass ==="
echo "Check ralph/qa-report.json for the full attempt history."
