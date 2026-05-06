#!/bin/bash
# Reset ralph cycle state. Archives previous cycle to ralph/.archive/<ts>/ by default.
#
# Usage:
#   ralph reset                          archive + clear state, empty tasks.raw.md
#   ralph reset path/to/new-raw.md       archive + clear state, copy file to tasks.raw.md
#   ralph reset --hard                   clear state without archiving
#   ralph reset --force                  skip uncommitted-change guard
set -euo pipefail

[ -n "${RALPH_INSTALL:-}" ] || RALPH_INSTALL="$(dirname "$(dirname "$(readlink -f "$0")")")"

HARD=0
FORCE=0
RAW_SRC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --hard)  HARD=1;  shift ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --) shift; break ;;
    -*) echo "Error: unknown option '$1'"; exit 1 ;;
    *)
      if [ -z "$RAW_SRC" ]; then RAW_SRC="$1"; shift
      else echo "Error: too many arguments ('$1')"; exit 1
      fi ;;
  esac
done

[ -d ralph ] || { echo "Error: ralph/ directory not found. Run from the project root where ralph/ exists."; exit 1; }
command -v jq >/dev/null || { echo "Error: jq is required."; exit 1; }

if [ -n "$RAW_SRC" ] && [ ! -f "$RAW_SRC" ]; then
  echo "Error: specified raw file not found: $RAW_SRC"; exit 1
fi

if [ "$FORCE" -ne 1 ] && command -v git >/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  DIRTY=$(git status --porcelain -- ralph/tasks.json ralph/tasks.raw.md \
                                     ralph/plan-progress.txt ralph/build-progress.txt \
                                     ralph/qa-report.json ralph/qa-hints.json \
                                     ralph/.plan-complete 2>/dev/null || true)
  if [ -n "$DIRTY" ]; then
    echo "Error: uncommitted changes found in ralph state files."
    echo "$DIRTY"
    echo ""
    echo "Commit or stash them, or use --force to proceed anyway."
    exit 1
  fi
fi

STATE_FILES=(
  ralph/tasks.json
  ralph/tasks.raw.md
  ralph/plan-progress.txt
  ralph/build-progress.txt
  ralph/qa-report.json
  ralph/qa-hints.json
)

need_archive=0
if [ "$HARD" -ne 1 ]; then
  for f in "${STATE_FILES[@]}"; do
    if [ -s "$f" ]; then
      case "$f" in
        *.json)
          if [ "$(jq 'if type=="array" then length else 1 end' "$f" 2>/dev/null || echo 1)" != "0" ]; then
            need_archive=1; break
          fi ;;
        *) need_archive=1; break ;;
      esac
    fi
  done
  [ -f ralph/.plan-complete ] && need_archive=1
  # Backward compat: legacy .plan-complete at cwd from pre-fix versions
  [ -f .plan-complete ] && need_archive=1
fi

if [ "$need_archive" -eq 1 ]; then
  TS=$(date +%Y%m%d-%H%M%S)
  ARCHIVE_DIR="ralph/.archive/$TS"
  mkdir -p "$ARCHIVE_DIR"
  for f in "${STATE_FILES[@]}"; do
    [ -e "$f" ] && mv "$f" "$ARCHIVE_DIR/$(basename "$f")"
  done
  [ -f ralph/.plan-complete ] && mv ralph/.plan-complete "$ARCHIVE_DIR/.plan-complete"
  # Backward compat: also archive legacy cwd location if present
  [ -f .plan-complete ] && mv .plan-complete "$ARCHIVE_DIR/.plan-complete.legacy"
  echo "Previous cycle archived: $ARCHIVE_DIR"
elif [ "$HARD" -eq 1 ]; then
  echo "--hard: skipping archive."
else
  echo "No previous cycle state found — skipping archive."
fi

echo '[]' > ralph/tasks.json
echo '[]' > ralph/qa-report.json
echo '[]' > ralph/qa-hints.json
: > ralph/plan-progress.txt
: > ralph/build-progress.txt
rm -f ralph/.plan-complete
# Backward compat: clean up legacy cwd location too
rm -f .plan-complete

if [ -n "$RAW_SRC" ]; then
  cp "$RAW_SRC" ralph/tasks.raw.md
  echo "tasks.raw.md <- $RAW_SRC"
else
  : > ralph/tasks.raw.md
  echo "tasks.raw.md cleared. Write your requirements then run 'ralph run'."
fi

echo "Reset complete."
