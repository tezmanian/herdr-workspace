#!/usr/bin/env bash
# Runs in the new worktree (WS_SETUP). Starts DDEV under a project name of its own and exports what the frontend needs.
set -euo pipefail

NAME=$(basename "$PWD")                                   # the workspace name, e.g. PROJ-123
# A port slot of its own (10..89): one file per taken slot holding the worktree path. noclobber makes the claim atomic,
# so two setups running at once never get the same slot; a rerun finds its own file again. teardown.sh frees it.
SLOTS=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-workspace-slots
mkdir -p "$SLOTS"
SLOT=$(grep -lxF "$PWD" "$SLOTS"/* 2>/dev/null | head -1 || true)
SLOT=${SLOT##*/}
if [[ -z "$SLOT" ]]; then
    for n in $(seq 10 89); do
        [[ ! -f "$SLOTS/$n" || -d "$(cat "$SLOTS/$n")" ]] || rm -f "$SLOTS/$n"      # its worktree is gone: free again
        if (set -o noclobber; echo "$PWD" > "$SLOTS/$n") 2>/dev/null; then SLOT=$n; break; fi
    done
fi
[[ -n "$SLOT" ]] || { echo "No free slot in $SLOTS."; exit 1; }

ddev config --project-name "api-$(echo "$NAME" | tr 'A-Z_' 'a-z-')" --project-type php >/dev/null
ddev start
ddev composer install --no-interaction

# Everything appended here is handed to the sub workspaces (and shown by ws-status.sh).
{
    echo "API_URL=https://$(ddev describe -j | jq -r '.raw.hostname')"
    echo "WS_SLOT=$SLOT"
} >> "$WS_EXPORT"
