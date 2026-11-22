#!/usr/bin/env bash
# Checks what herdr-workspace needs for the main project (current repo) and its sub repos. Prints ok/warn/FAIL per item;
# exits 1 when something required is missing (a tool, a backend, a repo, a base branch, a configured agent program).
# Usage (inside any checkout of the main project): ws-doctor.sh [sub repo]... [--on MACHINE --remote-dir DIR]
set -uo pipefail
source "$(dirname "$0")/lib.sh"
ws_help "$@"
ws_remote "$@"
FAILED=0
ok() { echo "ok    $*"; }
warn() { echo "warn  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }

for t in git jq rsync; do
    command -v "$t" >/dev/null && ok "$t found" || fail "$t missing"
done
case "$WS_BACKEND" in
    herdr) ok "backend: Herdr 1 (herdr)" ;;
    core) ok "backend: herdr-core (hc)" ;;
    *)
        if ! command -v herdr >/dev/null && ! command -v hc >/dev/null; then fail "no backend: neither herdr nor hc is installed"
        else fail "no backend: run inside a Herdr pane (HERDR_ENV=1) or start herdr-core (hc server status)"; fi ;;
esac

# Agent programs named in a config (WS_<ROLE>_AGENT, default claude) must be on PATH.
check_agents() {
    local v a seen=" "
    for v in WS_ORCHESTRATOR_AGENT WS_PLAN_AGENT WS_IMPLEMENT_AGENT WS_REVIEW_AGENT WS_DECIDE_AGENT; do
        a=${!v:-}
        [[ -n "$a" && "$seen" != *" $a "* ]] || continue
        seen="$seen$a "
        command -v "$a" >/dev/null && ok "agent $a found" || fail "agent $a not on PATH ($v in $(basename "$1"))"
    done
}

check_repo() {
    local repo=$1 role=$2
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { fail "$role $repo is not a git repository"; return; }
    ok "$role $(basename "$repo") is a git repository"
    unset WS_PLAN_AGENT WS_IMPLEMENT_AGENT WS_REVIEW_AGENT WS_DECIDE_AGENT   # not reset by ws_config
    ws_config "$repo"
    [[ -n "$WS_CONFIG_DIR" ]] && ok "config: $WS_CONFIG_DIR" || warn "no config for $(basename "$repo"): plain worktrees (skill herdr-workspace-config)"
    # New branches start from WS_BASE_BRANCH (default master), so a missing one breaks ws-start.sh.
    if git -C "$repo" rev-parse -q --verify "$WS_BASE_BRANCH^{commit}" >/dev/null 2>&1; then ok "base branch $WS_BASE_BRANCH exists"
    elif git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$WS_BASE_BRANCH" >/dev/null; then
        fail "base branch $WS_BASE_BRANCH exists only as origin/$WS_BASE_BRANCH in $(basename "$repo"): check it out once, or set WS_BASE_BRANCH=origin/$WS_BASE_BRANCH"
    else
        fail "base branch $WS_BASE_BRANCH not found in $(basename "$repo"): set WS_BASE_BRANCH in its config (current branch: $(git -C "$repo" branch --show-current 2>/dev/null))"
    fi
    check_agents "$repo"
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
