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
.plan-complete
.ralph-watchdog.lock
ralph-watchdog-*.log
IGNORE
  echo "Updated: .gitignore"
fi

echo ""
echo "Done. Next steps:"
echo "  1. Edit ralph/ralph-config.json for your project"
echo "  2. echo 'your requirements' >> ralph/tasks.raw.md"
echo "  3. ralph run"
