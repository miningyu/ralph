#!/bin/bash
# Shared utilities sourced by plan/build/qa/watchdog scripts.
# Source this after `cd "$(dirname "$0")/.."` so ralph/ paths resolve correctly.

# macOS compatibility: GNU timeout fallback
if ! command -v timeout &>/dev/null; then
  if command -v gtimeout &>/dev/null; then
    timeout() { gtimeout "$@"; }
  else
    timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
  fi
fi

# tasks.json helpers — assumes CWD is project root
count_passes() { jq '[.[] | select(.build_pass == true)] | length' ralph/tasks.json 2>/dev/null || echo "0"; }
qa_passed()    { jq '[.[] | select(.qa_pass == true)]    | length' ralph/tasks.json 2>/dev/null || echo "0"; }
total_tasks()  { jq 'length' ralph/tasks.json 2>/dev/null || echo "0"; }
