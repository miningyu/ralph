#!/bin/bash
# Scaffold ralph state directory in current project.
set -euo pipefail

[ -n "${RALPH_INSTALL:-}" ] || RALPH_INSTALL="$(dirname "$(dirname "$(readlink -f "$0")")")"

echo "Initializing ralph in $(pwd)..."

if [ -f ralph/ralph-config.json ]; then
  echo "ralph/ralph-config.json already exists — skipping."
else
  mkdir -p ralph
  cp "${RALPH_INSTALL}/templates/ralph-config.example.json" ralph/ralph-config.json
  echo "Created: ralph/ralph-config.json (edit this before running)"
fi

[ -f ralph/tasks.json ]        || echo '[]' > ralph/tasks.json
[ -f ralph/qa-report.json ]    || echo '[]' > ralph/qa-report.json
[ -f ralph/qa-hints.json ]     || echo '[]' > ralph/qa-hints.json
[ -f ralph/plan-progress.txt ] || touch ralph/plan-progress.txt
[ -f ralph/build-progress.txt ]|| touch ralph/build-progress.txt
[ -f ralph/tasks.raw.md ]      || touch ralph/tasks.raw.md

GITIGNORE=".gitignore"
if ! grep -q "# ralph state" "$GITIGNORE" 2>/dev/null; then
  cat >> "$GITIGNORE" << 'IGNORE'

# ralph state
ralph/tasks.json
ralph/tasks.raw.md
ralph/plan-progress.txt
ralph/build-progress.txt
ralph/qa-report.json
ralph/qa-hints.json
ralph/.archive/
ralph/runtime-logs/
ralph/qa-artifacts/
ralph/.qa-cache/
ralph/.plan-complete
ralph/.current-task-*.json
.ralph-watchdog.lock
ralph-watchdog-*.log
IGNORE
  echo "Updated: .gitignore"
fi

# Untrack any ralph state files that were previously committed (before gitignore was set up).
# Only ralph/ralph-config.json should be tracked.
TRACKED_STATE=$(git ls-files ralph/ 2>/dev/null | grep -v '^ralph/ralph-config\.json$' || true)
if [ -n "$TRACKED_STATE" ]; then
  echo "$TRACKED_STATE" | xargs -I {} git rm --cached --quiet "{}" 2>/dev/null || true
  echo "Untracked $(echo "$TRACKED_STATE" | wc -l | tr -d ' ') previously-tracked ralph state file(s) — commit this change manually if desired."
fi

echo ""
echo "Done. Next steps:"
echo "  1. Edit ralph/ralph-config.json for your project"
echo "  2. echo 'your requirements' >> ralph/tasks.raw.md"
echo "  3. ralph run"
