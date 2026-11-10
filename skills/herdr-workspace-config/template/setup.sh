#!/usr/bin/env bash
# Repo setup for herdr-workspace (WS_SETUP). Runs in the new worktree. Replace the examples with what the repo needs.
set -euo pipefail

# Start the dev environment, e.g.: ddev start | vagrant up | docker compose up -d

# Install without touching tracked lock files, e.g.: npm install --no-audit --no-fund --package-lock=false

# Wire to the main project when it exported an API, e.g. a Next.js app:
# [[ -z "${API_URL:-}" ]] || echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.local

# Own dev port per slot so parallel workspaces don't collide, e.g.:
# echo "DEV_PORT=$((3000 + ${WS_SLOT:-10}))" >> "$WS_EXPORT"
