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
qa_blocked()   { jq '[.[] | select((.qa_status // "") as $s | $s == "blocked" or $s == "infra_blocked")] | length' ralph/tasks.json 2>/dev/null || echo "0"; }
total_tasks()  { jq 'length' ralph/tasks.json 2>/dev/null || echo "0"; }

# ── QA validation cache + path helpers ────────────────────────────────────────
# The cache lets the watchdog and qa-ralph.sh skip an LLM agent invocation when
# lint/typecheck/test results for a given (scope, content) are already known.
# Cache key invalidates whenever the scope's path or any shared library's path
# (workspaces.packages[]) changes its tree SHA in HEAD.

qa_cache_dir() {
  jq -r '.evaluator.cacheDir // "ralph/.qa-cache"' ralph/ralph-config.json 2>/dev/null || echo "ralph/.qa-cache"
}

scope_to_path() {
  local scope="$1"
  [ -n "$scope" ] || { echo ""; return; }
  jq -r --arg s "$scope" '
    [.workspaces.apps[]?, .workspaces.packages[]?]
    | map(select(.name == $s))
    | first
    | .path // empty
  ' ralph/ralph-config.json 2>/dev/null
}

scope_tree_sha() {
  local scope="$1"
  local p
  p=$(scope_to_path "$scope")
  [ -n "$p" ] || { echo "no-path"; return; }
  git rev-parse "HEAD:$p" 2>/dev/null || echo "no-tree"
}

shared_libs_combined_sha() {
  jq -r '.workspaces.packages[]?.path // empty' ralph/ralph-config.json 2>/dev/null \
    | sort \
    | while IFS= read -r p; do
        [ -z "$p" ] && continue
        git rev-parse "HEAD:$p" 2>/dev/null || echo "no-tree"
      done \
    | shasum 2>/dev/null \
    | awk '{print $1}'
}

qa_cache_lookup() {
  # args: scope, command_name
  # echos "0" if a green cached result exists for the current (scope tree + shared libs) state; "MISS" otherwise.
  local scope="$1" cmd="$2"
  [ -n "$scope" ] && [ -n "$cmd" ] || { echo "MISS"; return; }
  local tree_sha libs_sha cache_dir cache_file exit_code
  tree_sha=$(scope_tree_sha "$scope")
  libs_sha=$(shared_libs_combined_sha)
  cache_dir="$(qa_cache_dir)/${scope}/${tree_sha}_${libs_sha}"
  cache_file="${cache_dir}/${cmd}.json"
  [ -f "$cache_file" ] || { echo "MISS"; return; }
  exit_code=$(jq -r '.exit_code // -1' "$cache_file" 2>/dev/null || echo -1)
  if [ "$exit_code" = "0" ]; then echo "0"; else echo "MISS"; fi
}

qa_cache_save() {
  # args: scope, command_name, exit_code, log_path
  local scope="$1" cmd="$2" exit_code="$3" log_path="$4"
  [ -n "$scope" ] && [ -n "$cmd" ] || return 0
  local tree_sha libs_sha cache_dir tail_log
  tree_sha=$(scope_tree_sha "$scope")
  libs_sha=$(shared_libs_combined_sha)
  cache_dir="$(qa_cache_dir)/${scope}/${tree_sha}_${libs_sha}"
  mkdir -p "$cache_dir"
  tail_log=""
  [ -f "$log_path" ] && tail_log=$(tail -n 80 "$log_path" 2>/dev/null || true)
  jq -n --argjson code "$exit_code" --arg log "$tail_log" --arg cmd "$cmd" \
        --arg scope_sha "$tree_sha" --arg libs "$libs_sha" --arg path "$log_path" '
    {command: $cmd, scope: ($scope_sha), libs_sha: $libs, exit_code: $code, log_path: $path, log_tail: $log, cached_at: now}
  ' > "${cache_dir}/${cmd}.json"
}

# ── Per-task no-op skip helpers ───────────────────────────────────────────────
# Used to skip QA entirely when a task previously passed and no file in its
# path∪touches has changed since.

task_path_set() {
  # args: task_id (reads ralph/tasks.json). Echos newline-separated workspace paths.
  local task_id="$1"
  jq -r --arg id "$task_id" '
    [.[] | select(.id == $id)] | first
    | (([.path // empty] + (.touches // []))
       | map(select(. != null and . != ""))
       | unique
       | .[])
  ' ralph/tasks.json 2>/dev/null
}

# Resolve a list of workspace names (scopes) to filesystem paths via ralph-config.json.
# Workspace names that don't resolve are returned as-is (caller may pass paths directly).
task_path_set_resolved() {
  local task_id="$1"
  local raw resolved
  while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    resolved=$(scope_to_path "$raw")
    if [ -n "$resolved" ]; then
      echo "$resolved"
    else
      echo "$raw"
    fi
  done < <(task_path_set "$task_id")
}

last_pass_sha_for_task() {
  # args: task_id, task_spec_key
  local task_id="$1" key="$2"
  [ -f ralph/qa-report.json ] || { echo ""; return; }
  jq -r --arg id "$task_id" --arg key "$key" '
    [.[] | select(.task_id == $id and (.task_spec_key // "") == $key and .status == "pass" and (.git_sha // "") != "")]
    | last | .git_sha // ""
  ' ralph/qa-report.json 2>/dev/null
}

task_files_changed_since() {
  # args: task_id, sha. Echos non-empty if any file changed; empty if unchanged.
  local task_id="$1" sha="$2"
  [ -n "$sha" ] || { echo "no-sha"; return; }
  local paths_arr=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] && paths_arr+=("$p")
  done < <(task_path_set_resolved "$task_id")
  [ "${#paths_arr[@]}" -gt 0 ] || { echo "no-paths"; return; }
  git rev-parse --verify "$sha" >/dev/null 2>&1 || { echo "missing-sha"; return; }
  local diff
  diff=$(git diff --name-only "$sha" HEAD -- "${paths_arr[@]}" 2>/dev/null || echo "diff-error")
  [ -z "$diff" ] && return 0
  echo "$diff"
}

# ── Per-kind QA timeout ───────────────────────────────────────────────────────
per_kind_timeout() {
  local kind="$1"
  local default_to
  default_to=$(jq -r '.evaluator.iterationTimeoutSeconds // 600' ralph/ralph-config.json 2>/dev/null || echo 600)
  jq -r --arg k "$kind" --argjson d "$default_to" '.evaluator.kindTimeoutOverride[$k] // $d' ralph/ralph-config.json 2>/dev/null || echo "$default_to"
}

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
