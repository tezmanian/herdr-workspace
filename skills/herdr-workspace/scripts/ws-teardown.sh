#!/usr/bin/env bash
# Runs the repo's WS_TEARDOWN in the worktree (current directory or $WS_WORKTREE_PATH). ws-stop.sh calls it;
# Herdr has no archive hook, so a worktree removed in Herdr itself skips it: run this first.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "${WS_WORKTREE_PATH:-$PWD}"
ws_config "$(ws_main .)"
[[ -z "$WS_TEARDOWN" ]] || eval "$WS_TEARDOWN"
