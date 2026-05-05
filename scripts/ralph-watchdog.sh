#!/bin/bash
# ralph-watchdog.sh — top-level orchestrator. Runs plan -> build -> QA with restart logic.
#
# Phases:
#   1. plan-ralph.sh — refines ralph/tasks.json until .plan-complete is created
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
plan_done() { [ -f .plan-complete ]; }

cron_backup() {
  git status --porcelain ralph/ .plan-complete 2>/dev/null | grep -q . || return 0
  git add ralph/ .plan-complete 2>/dev/null || true
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
