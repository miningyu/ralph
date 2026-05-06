#!/bin/bash
# Shared utilities sourced by plan/build/qa/watchdog scripts.

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

require_agent_command() {
  local agent_cmd="$1"
  local field_name="$2"
  local executable

  executable=$(printf '%s\n' "$agent_cmd" | awk '{
    for (i = 1; i <= NF; i++) {
      if ($i !~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
        print $i
        exit
      }
    }
  }')

  [ -n "$executable" ] || { echo "Error: ${field_name} is empty."; exit 1; }
  command -v "$executable" >/dev/null || {
    echo "Error: ${executable} CLI not found in PATH (from ${field_name})."
    exit 1
  }
}
