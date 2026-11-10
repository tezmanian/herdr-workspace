#!/usr/bin/env bash
# Shows workspace <name> (or all workspaces of the main project): worktrees, branch, setup state, exports, config used.
# Usage (inside any checkout of the main project): ws-status.sh [name] [--on MACHINE --remote-dir DIR]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ws_remote "$@"
MAIN=$(ws_main .)
DIR=$(ws_dir "$MAIN")

show() {
    local wt=$1 head=$2 indent=$3 state
    if [[ ! -d "$wt" ]]; then printf '%s%s  MISSING (removed outside ws-stop.sh; ws-stop.sh cleans it up)\n' "$head" "$wt"; return; fi
    state=$(ws_state "$wt")
    ws_config "$(ws_main "$wt")"
    printf '%s%s  [%s]  %s\n' "$head" "$wt" "$(git -C "$wt" branch --show-current)" \
        "$([[ -f "$state" ]] && echo ready || { [[ -f "$state.failed" ]] && echo "setup FAILED" || echo "setup pending"; })"
    printf '%sconfig: %s\n' "$indent" "${WS_CONFIG_DIR:-none}"
    [[ ! -s "$state" ]] || sed "s/^/$indent/" "$state"
}

FOUND=0
for f in "$DIR"/*.env; do
    [[ -f "$f" ]] || continue
    n=$(basename "$f" .env)
    [[ -z "${1:-}" || "$n" == "$1" ]] || continue
    FOUND=1
    echo "== $n"
    show "$(ws_get "$MAIN" "$n" main)" "" "  "
    for sub in $(ws_children "$MAIN" "$n"); do show "$sub" "  └ " "      "; done
    echo
done
((FOUND)) || { echo "No workspace ${1:-}."; exit 1; }
