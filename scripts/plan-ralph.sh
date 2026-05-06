#!/bin/bash
# Phase 1: Plan — refine ralph/tasks.json from requirements
set -euo pipefail

[ -n "${RALPH_INSTALL:-}" ] || RALPH_INSTALL="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "${RALPH_INSTALL}/scripts/ralph-lib.sh"

ITERATIONS="${1:-50}"

[ -f ralph/ralph-config.json ] || { echo "Error: ralph/ralph-config.json not found. Run 'ralph init' first."; exit 1; }
command -v jq >/dev/null || { echo "Error: jq is required."; exit 1; }
command -v claude >/dev/null || { echo "Error: claude CLI not found in PATH."; exit 1; }

TARGET_NAME=$(jq -r '.projectName' ralph/ralph-config.json)
BUILDER_CMD=$(jq -r '.builder.command' ralph/ralph-config.json)
ITER_TIMEOUT=$(jq -r '.builder.iterationTimeoutSeconds' ralph/ralph-config.json)

echo "=== ${TARGET_NAME} ralph: Phase 1 (Plan) ==="
echo "Iterations: $ITERATIONS"
echo "Builder: $BUILDER_CMD"
echo ""

[ -f ralph/tasks.json ]        || echo '[]' > ralph/tasks.json
[ -f ralph/plan-progress.txt ] || touch ralph/plan-progress.txt

RAW_REF=""
[ -f ralph/tasks.raw.md ] && RAW_REF="@ralph/tasks.raw.md"

for ((i=1; i<=$ITERATIONS; i++)); do
  echo "--- Plan iteration $i/$ITERATIONS ---"

  if [ -f ralph/.plan-complete ]; then
    echo "Plan is already complete (ralph/.plan-complete exists). Exiting."
    exit 0
  fi

  result=$(timeout "$ITER_TIMEOUT" $BUILDER_CMD \
"@${RALPH_INSTALL}/prompts/plan-prompt.md @ralph/ralph-config.json @ralph/tasks.json @ralph/plan-progress.txt $RAW_REF

ITERATION: $i of $ITERATIONS

Refine or extend ralph/tasks.json by exactly ONE unit (one of Mode A/B/C/D from the prompt). Then commit, push, and stop.
If there is more plan work remaining, output <promise>NEXT</promise>.
Output <promise>PLAN_COMPLETE</promise> only when the backlog is ready to move to the build phase.")

  echo "$result"

  if [[ "$result" == *"<promise>PLAN_COMPLETE</promise>"* ]]; then
    touch ralph/.plan-complete
    echo ""
    echo "=== Plan complete after $i iteration(s) ==="
    exit 0
  fi

  if [[ "$result" == *"<promise>NEXT</promise>"* ]]; then
    echo "Plan unit complete. Continuing..."
    continue
  fi

  echo "Warning: no promise found. Agent may have crashed or hit context limit. Restarting..."
  sleep 3
done

echo ""
echo "=== Plan ended after $ITERATIONS iterations ==="
echo "Tasks: $(jq 'length' ralph/tasks.json) (review ralph/tasks.json)"
