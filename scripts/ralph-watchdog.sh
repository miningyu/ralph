#!/bin/bash
# ralph-watchdog.sh — top-level orchestrator. Runs plan -> build -> QA with restart logic.
#
# Phases:
#   1. plan-ralph.sh — refines ralph/tasks.json until ralph/.plan-complete is created
#   2. build-ralph.sh — implements tasks until all are build_pass:true
#   3. qa-ralph.sh — validates tasks until all are qa_pass:true (or retries exhausted)
#   If QA finds regressions, falls back to phase 2.
#
# Usage: ralph run   (from project root)
set -euo pipefail

[ -n "${RALPH_INSTALL:-}" ] || RALPH_INSTALL="$(dirname "$(dirname "$(readlink -f "$0")")")"

# cron doesn't load login shell profile — source common profile files to pick up PATH
for _profile in "$HOME/.zprofile" "$HOME/.bash_profile" "$HOME/.profile"; do
  [ -f "$_profile" ] && source "$_profile" && break
done
unset _profile

source "${RALPH_INSTALL}/scripts/ralph-lib.sh"

LOCKFILE=".ralph-watchdog.lock"
LOG_FILE="ralph-watchdog-$(date +%Y%m%d-%H%M%S).log"

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

if [ -f "$LOCKFILE" ]; then
  PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    echo "Watchdog is already running (PID $PID)."
    exit 0
  fi
  rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

[ -f ralph/ralph-config.json ] || { log "Error: ralph/ralph-config.json not found. Run 'ralph init' first."; exit 1; }
command -v jq >/dev/null || { log "Error: jq is required."; exit 1; }
TARGET_NAME=$(jq -r '.projectName' ralph/ralph-config.json)

all_built() {
  local total=$(total_tasks); local passed=$(count_passes)
  [ "$total" -gt 0 ] && [ "$passed" -ge "$total" ]
}
all_qa_passed() {
  local total=$(total_tasks); local passed=$(qa_passed)
  [ "$total" -gt 0 ] && [ "$passed" -ge "$total" ]
}
any_qa_blocked() {
  [ "$(qa_blocked)" -gt 0 ]
}
plan_done() { [ -f ralph/.plan-complete ]; }

reset_pass_flags() {
  jq '
    map(.build_pass = false | .qa_pass = false)
  ' ralph/tasks.json > ralph/tasks.json.tmp && mv ralph/tasks.json.tmp ralph/tasks.json
}

run_scoped_command() {
  local label="$1"
  local template="$2"
  local scope="$3"
  local command="${template//\{scope\}/$scope}"

  [ -z "$command" ] && return 0
  log "Phase 2: final $label for $scope: $command"
  bash -lc "$command" >> "$LOG_FILE" 2>&1
}

# Run lint/typecheck/test individually for a scope and write each result into
# the QA cache so per-task QA can skip an LLM invocation on cached pass.
warm_qa_cache_for_scope() {
  local scope="$1"
  local cfg=ralph/ralph-config.json
  local name template cmd log_file exit_code cached
  for name in lint typecheck test; do
    template=$(jq -r --arg n "$name" '.commands[$n] // empty' "$cfg" 2>/dev/null)
    [ -n "$template" ] || continue
    cached=$(qa_cache_lookup "$scope" "$name")
    if [ "$cached" = "0" ]; then
      log "Phase 2 gate: ${scope}.${name} PASS (cached)"
      continue
    fi
    cmd="${template//\{scope\}/$scope}"
    mkdir -p ralph/.qa-cache/_logs
    log_file="ralph/.qa-cache/_logs/gate-${scope}-${name}-$(date +%s).log"
    log "Phase 2 gate: ${scope}.${name} running"
    exit_code=0
    bash -lc "$cmd" >"$log_file" 2>&1 || exit_code=$?
    qa_cache_save "$scope" "$name" "$exit_code" "$log_file"
    if [ "$exit_code" -ne 0 ]; then
      log "Phase 2 gate: ${scope}.${name} FAILED (exit=${exit_code}). See $log_file"
      tail -n 40 "$log_file" | sed 's/^/    /' | tee -a "$LOG_FILE" >/dev/null
      return 1
    fi
    log "Phase 2 gate: ${scope}.${name} PASS"
  done
}

# Iterate over the union of every task's scope and touches[]. Run individual
# commands.lint/typecheck/test per workspace and cache them. Fall back to
# commands.final (legacy) only when none of the individual commands are set.
run_final_validation() {
  local has_individual=0
  for c in lint typecheck test; do
    if [ -n "$(jq -r --arg n "$c" '.commands[$n] // empty' ralph/ralph-config.json 2>/dev/null)" ]; then
      has_individual=1
      break
    fi
  done

  local final_template
  final_template=$(jq -r '.commands.final // .commands.finalValidation // empty' ralph/ralph-config.json)

  if [ "$has_individual" -eq 0 ] && [ -z "$final_template" ]; then
    return 0
  fi

  local scope
  while IFS= read -r scope; do
    [ -z "$scope" ] && continue
    if [ "$has_individual" -eq 1 ]; then
      if ! warm_qa_cache_for_scope "$scope"; then
        log "Phase 2: final validation failed at $scope (individual commands)."
        return 1
      fi
    elif [ -n "$final_template" ]; then
      if ! run_scoped_command "validation" "$final_template" "$scope"; then
        log "Phase 2: final validation failed for $scope."
        return 1
      fi
    fi
  done < <(jq -r '
    [.[] | (.scope // empty), (.touches // [] | .[])]
    | map(select(. != null and . != ""))
    | unique
    | .[]
  ' ralph/tasks.json)

  log "Phase 2: final validation passed (scope ∪ touches[] union)."
}

http_responsive() {
  local url="$1"
  local status
  status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 "$url" 2>/dev/null || echo "000")
  [ "$status" != "000" ]
}

wait_for_url() {
  local url="$1"
  local waited=0
  while [ "$waited" -lt 120 ]; do
    if http_responsive "$url"; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

run_final_runtime_smoke() {
  local mode
  mode=$(jq -r '.validation.runtimeSmoke // "perTask"' ralph/ralph-config.json)
  [ "$mode" = "final" ] || return 0

  local backend_port backend_health backend_dev backend_url
  backend_port=$(jq -r '.runtime.backend.port // empty' ralph/ralph-config.json)
  backend_health=$(jq -r '.runtime.backend.healthPath // "/"' ralph/ralph-config.json)
  backend_dev=$(jq -r '.runtime.backend.devCommand // empty' ralph/ralph-config.json)

  if [ -n "$backend_port" ]; then
    backend_url="http://localhost:${backend_port}${backend_health}"
    if ! http_responsive "$backend_url" && [ -n "$backend_dev" ]; then
      mkdir -p ralph/runtime-logs
      local backend_log="ralph/runtime-logs/backend-final-$(date +%Y%m%d-%H%M%S).log"
      log "Phase 2: starting backend for final runtime smoke: $backend_dev"
      bash -lc "$backend_dev" >"$backend_log" 2>&1 &
      disown "$!" 2>/dev/null || true
    fi
    if ! wait_for_url "$backend_url"; then
      log "Phase 2: final backend runtime smoke failed: $backend_url"
      return 1
    fi
    log "Phase 2: final backend runtime smoke passed: $backend_url"
  fi

  local frontend_url frontend_dev
  frontend_url=$(jq -r '.runtime.frontend.previewUrl // empty' ralph/ralph-config.json)
  frontend_dev=$(jq -r '.runtime.frontend.devCommand // empty' ralph/ralph-config.json)

  if [ -n "$frontend_url" ]; then
    if ! http_responsive "$frontend_url" && [ -n "$frontend_dev" ]; then
      mkdir -p ralph/runtime-logs
      local frontend_log="ralph/runtime-logs/frontend-final-$(date +%Y%m%d-%H%M%S).log"
      log "Phase 2: starting frontend for final runtime smoke: $frontend_dev"
      bash -lc "$frontend_dev" >"$frontend_log" 2>&1 &
      disown "$!" 2>/dev/null || true
    fi
    if ! wait_for_url "$frontend_url"; then
      log "Phase 2: final frontend runtime smoke failed: $frontend_url"
      return 1
    fi
    log "Phase 2: final frontend runtime smoke passed: $frontend_url"
  fi
}

cron_backup() {
  local status meaningful
  status=$(git status --porcelain ralph/ 2>/dev/null || true)
  [ -n "$status" ] || return 0

  meaningful=$(printf '%s\n' "$status" | awk '{print $2}' | grep -Ev '^ralph/(qa-report\.json|\.current-task-[0-9]+\.json)$' || true)
  [ -n "$meaningful" ] || return 0

  git add ralph/ 2>/dev/null || true
  git commit -m "watchdog backup $(date '+%H:%M') — build $(count_passes)/$(total_tasks), qa $(qa_passed)/$(total_tasks)" 2>/dev/null || true
  git push 2>/dev/null || true
}

START_TIME=$(date +%s)
log "=== ${TARGET_NAME} ralph watchdog starting ==="
log "Start time: $(date '+%Y-%m-%d %H:%M:%S')"

# ─── PHASE 1: Plan ───
MAX_PLAN_RESTARTS=5
plan_restarts=0
while ! plan_done; do
  if [ "$plan_restarts" -ge "$MAX_PLAN_RESTARTS" ]; then
    log "Phase 1: max restarts reached ($MAX_PLAN_RESTARTS). Aborting."
    exit 1
  fi
  log "Phase 1: running plan loop... (attempt $((plan_restarts + 1)))"
  "${RALPH_INSTALL}/scripts/plan-ralph.sh" || true
  cron_backup
  if plan_done; then
    log "Phase 1: complete. $(total_tasks) task(s) queued."
    break
  fi
  plan_restarts=$((plan_restarts + 1))
  log "Phase 1: plan stalled but not complete. Restarting..."
  sleep 5
done

# ─── PHASE 2 + 3: Build → QA → Fix loop ───
MAX_CYCLES=10
for ((cycle=1; cycle<=MAX_CYCLES; cycle++)); do
  log ""
  log "===== CYCLE $cycle/$MAX_CYCLES ====="

  # ─── PHASE 2: Build ───
  MAX_BUILD_RESTARTS=10
  build_restarts=0
  while ! all_built; do
    if [ "$build_restarts" -ge "$MAX_BUILD_RESTARTS" ]; then
      log "Phase 2: max restarts reached ($MAX_BUILD_RESTARTS). Moving to QA."
      break
    fi
    log "Phase 2: building... $(count_passes)/$(total_tasks) (attempt $((build_restarts + 1)))"
    rc=0; "${RALPH_INSTALL}/scripts/build-ralph.sh" || rc=$?
    cron_backup
    if all_built; then
      log "Phase 2: all $(total_tasks) tasks build_pass."
      if ! run_final_validation; then
        log "Phase 2: final validation failed. Resetting pass flags and returning to build."
        reset_pass_flags
        cron_backup
        continue
      fi
      if ! run_final_runtime_smoke; then
        log "Phase 2: final runtime smoke failed. Resetting pass flags and returning to build."
        reset_pass_flags
        cron_backup
        continue
      fi
      break
    fi
    if [ "$rc" -eq 2 ]; then
      log "Phase 2: BLOCKED (unsatisfied dependencies). Check ralph/tasks.json. Aborting cycle."
      exit 2
    fi
    build_restarts=$((build_restarts + 1))
    REMAINING=$(($(total_tasks) - $(count_passes)))
    log "Phase 2: build stalled with $REMAINING task(s) remaining. Restarting..."
    sleep 5
  done

  # ─── PHASE 3: QA ───
  MAX_QA_RESTARTS=10
  qa_restarts=0
  while ! all_qa_passed && [ "$qa_restarts" -lt "$MAX_QA_RESTARTS" ]; do
    qa_restarts=$((qa_restarts + 1))
    log "Phase 3: running QA... $(qa_passed)/$(total_tasks) qa_pass (attempt $qa_restarts/$MAX_QA_RESTARTS)"
    "${RALPH_INSTALL}/scripts/qa-ralph.sh" || true
    cron_backup
    if any_qa_blocked; then
      log "Phase 3: QA blocked for $(qa_blocked) task(s). Human intervention required; stopping loop."
      exit 3
    fi
    if all_qa_passed; then
      log "Phase 3: all tasks qa_pass."
      break
    fi
  done

  if all_built && all_qa_passed; then
    log "=== All $(total_tasks) tasks: BUILD + QA verified ==="
    break
  fi

  if all_qa_passed; then
    log "Cycle $cycle: build not complete ($(count_passes)/$(total_tasks)). Restarting build..."
  else
    REMAINING_QA=$(($(total_tasks) - $(qa_passed)))
    AFTER_QA=$(count_passes)
    REMAINING_BUILD=$(($(total_tasks) - $AFTER_QA))
    if [ "$REMAINING_BUILD" -gt 0 ]; then
      log "Cycle $cycle: QA found regressions — $REMAINING_BUILD task(s) need rebuilding."
    else
      log "Cycle $cycle: $REMAINING_QA task(s) did not reach qa_pass within retry limit. Moving to next cycle."
    fi
  fi
done

cron_backup
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
H=$(( ELAPSED / 3600 ))
M=$(( (ELAPSED % 3600) / 60 ))
S=$(( ELAPSED % 60 ))
log ""
log "=========================================="
log "  ${TARGET_NAME} ralph: done"
log "  build_pass: $(count_passes)/$(total_tasks)"
log "  qa_pass:    $(qa_passed)/$(total_tasks)"
log "  elapsed:    ${H}h ${M}m ${S}s"
log "  log:        $LOG_FILE"
log "=========================================="
