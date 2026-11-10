#!/usr/bin/env bash
# Shows workspace <name> (or all workspaces of the main project): worktrees, branch, setup state, exports, config used.
# Usage (inside any checkout of the main project): ws-status.sh [name]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ws_remote "$@"
MAIN=$(ws_main .)
DIR=$(ws_dir "$MAIN")
NAMES=$(cd "$DIR" 2>/dev/null && ls *.env 2>/dev/null | sed 's/\.env$//' | { [[ -n "${1:-}" ]] && grep -x "$1" || cat; } || true)
[[ -n "$NAMES" ]] || { echo "No workspace ${1:-}."; exit 1; }

show() {
    local wt=$1 head=$2 indent=$3 state
    state=$(ws_state "$wt")
    ws_config "$(ws_main "$wt")"
    printf '%s%s  [%s]  %s\n' "$head" "$wt" "$(git -C "$wt" branch --show-current)" \
        "$([[ -f "$state" ]] && echo "ready" || echo "setup pending/failed")"
    printf '%sconfig: %s\n' "$indent" "${WS_CONFIG_DIR:-none}"
    [[ ! -s "$state" ]] || sed "s/^/$indent/" "$state"
}

for n in $NAMES; do
    echo "== $n"
    show "$(ws_get "$MAIN" "$n" main)" "" "  "
    for sub in $(ws_children "$MAIN" "$n"); do show "$sub" "  └ " "      "; done
    echo
done
