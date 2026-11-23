#!/usr/bin/env bash
# Runs in the worktree before it is removed (WS_TEARDOWN): stops the containers and frees the port slot setup.sh took.
set -uo pipefail

ddev delete -Oy
SLOTS=${XDG_STATE_HOME:-$HOME/.local/state}/herdr-workspace-slots
for f in "$SLOTS"/*; do
    if [[ -f "$f" ]] && grep -qxF "$PWD" "$f"; then rm -f "$f"; fi
done
