#!/usr/bin/env bash
# Checks what herdr-workspace needs for the main project (current repo) and its sub repos. Prints ok/warn/FAIL per item;
# exits 1 when something required is missing.
# Usage (inside any checkout of the main project): ws-doctor.sh [sub repo]... [--on MACHINE --remote-dir DIR]
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ws_remote "$@"
FAILED=0
ok() { echo "ok    $*"; }
warn() { echo "warn  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }

for t in git jq rsync; do
    command -v "$t" >/dev/null && ok "$t found" || fail "$t missing"
done
case "$WS_BACKEND" in
    herdr) ok "backend: Herdr 1" ;;
    core) ok "backend: herdr-core (hc)" ;;
    *) fail "no backend: run inside Herdr (HERDR_ENV=1) or start herdr-core (hc server status)" ;;
esac

check_repo() {
    local repo=$1 role=$2
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { fail "$role $repo is not a git repository"; return; }
    ok "$role $(basename "$repo") is a git repository"
    ws_config "$repo"
    [[ -n "$WS_CONFIG_DIR" ]] && ok "config: $WS_CONFIG_DIR" || warn "no config for $(basename "$repo"): plain worktrees (skill herdr-workspace-config)"
    git -C "$repo" rev-parse -q --verify "refs/heads/$WS_BASE_BRANCH" >/dev/null \
        && ok "base branch $WS_BASE_BRANCH exists" || warn "base branch $WS_BASE_BRANCH not found in $(basename "$repo") (WS_BASE_BRANCH)"
}

MAIN=$(ws_main . 2>/dev/null) || { fail "not inside a git repository"; exit 1; }
WS_MAIN_PROJECT=$MAIN
check_repo "$MAIN" main
SUBS=("$@")
((${#SUBS[@]})) || read -ra SUBS <<<"$WS_SUBS"
for s in ${SUBS[@]+"${SUBS[@]}"}; do
    repo=$(ws_repo_path "$s" 2>/dev/null) && check_repo "$repo" sub || fail "sub repo $s not found (path, or folder next to the main project)"
done
if command -v hc >/dev/null; then
    ms=$(hc machine ls --json 2>/dev/null | jq -r '.machines[]?.name' | tr '\n' ' ')
    ok "remote machines for --on: ${ms:-none (hc machine add <ssh host>)}"
fi
exit $FAILED
