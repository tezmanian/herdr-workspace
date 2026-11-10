#!/usr/bin/env bash
# Runs in the new worktree (WS_SETUP). Starts DDEV under a project name of its own and exports what the frontend needs.
set -euo pipefail

NAME=$(basename "$PWD")                                   # the workspace name, e.g. PROJ-123
SLOT=$(( $(pwd | cksum | cut -d' ' -f1) % 80 + 10 ))       # stable per worktree, 10..89

ddev config --project-name "api-$(echo "$NAME" | tr 'A-Z_' 'a-z-')" --project-type php >/dev/null
ddev start
ddev composer install --no-interaction

# Everything appended here is handed to the sub workspaces (and shown by ws-status.sh).
{
    echo "API_URL=https://$(ddev describe -j | jq -r '.raw.hostname')"
    echo "WS_SLOT=$SLOT"
} >> "$WS_EXPORT"
