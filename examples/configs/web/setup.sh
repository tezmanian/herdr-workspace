#!/usr/bin/env bash
# Runs in the new worktree after the API's setup finished; API_URL and WS_SLOT come from the API's exports.
set -euo pipefail

npm install --no-audit --no-fund --package-lock=false      # do not touch the tracked lock file

# Talk to this workspace's API, not the main checkout's.
[[ -z "${API_URL:-}" ]] || echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.local

# Own dev port per workspace, so two workspaces can run side by side.
echo "DEV_PORT=$((3000 + ${WS_SLOT:-10}))" >> "$WS_EXPORT"
