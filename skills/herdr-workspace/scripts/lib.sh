# Shared helpers for the herdr-workspace scripts (sourced).
WS_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# User-level configs for repos that should not carry their own.
WS_USER_HOME=${HERDR_WORKSPACE_HOME:-$HOME/.config/herdr-workspace}

# Main checkout of the repository containing $1.
ws_main() { git -C "$1" worktree list --porcelain | sed -n '1s/^worktree //p'; }

# Loads the first config found for the repo at $1 (main checkout):
# <repo>/.herdr/workspace/, <repo>/.agents/workspace/, $HERDR_WORKSPACE_HOME/projects/<repo dir name>/ (file workspace.env).
ws_config() {
    WS_BASE_BRANCH=master WS_SUBS="" WS_PLAN=worker WS_IGNORED_ON_REMOVE=ask
    WS_COPY="" WS_COPY_PATTERNS="" WS_COPY_EXCLUDE="" WS_CLONE="" WS_KEEP="" WS_KEEP_PATTERNS=""
    WS_SETUP="" WS_POST_SETUP="" WS_TEARDOWN="" WS_PLAN_BRIEF="" WS_IMPLEMENT_BRIEF="" WS_PLAN_SKILL="" WS_IMPLEMENT_SKILL="" WS_PLAN_BREAKS=""
    WS_ORCHESTRATOR_AGENT=claude WS_ORCHESTRATOR_MODEL="" WS_ORCHESTRATOR_EFFORT="" WS_ORCHESTRATOR_ARGS=""
    WS_PLAN_AGENT=claude WS_PLAN_MODEL="" WS_PLAN_EFFORT="" WS_PLAN_ARGS=""
    WS_IMPLEMENT_AGENT=claude WS_IMPLEMENT_MODEL="" WS_IMPLEMENT_EFFORT="" WS_IMPLEMENT_ARGS=""
    WS_REVIEW=off WS_REVIEW_SKILL="" WS_REVIEW_BRIEF="" WS_REVIEW_ROUNDS=2
    WS_REVIEW_AGENT=claude WS_REVIEW_MODEL="" WS_REVIEW_EFFORT="" WS_REVIEW_ARGS=""
    WS_AUTONOMY=off WS_DECIDE_SKILL="" WS_DECIDE_BRIEF="" WS_ESCALATE=""
    WS_DECIDE_AGENT=claude WS_DECIDE_MODEL="" WS_DECIDE_EFFORT="" WS_DECIDE_ARGS=""
    WS_PLANNER_AFTER="/compact" WS_IMPLEMENTER_AFTER="/clear" WS_IMPLEMENTER_AFTER_WHEN=workstream WS_DECIDER_AFTER=""
    WS_CONFIG_DIR=""
    local f
    for f in "$1/.herdr/workspace/workspace.env" "$1/.agents/workspace/workspace.env" "$WS_USER_HOME/projects/$(basename "$1")/workspace.env"; do
        [[ -f "$f" ]] || continue
        WS_CONFIG_DIR=$(dirname "$f")
        source "$f"
        break
    done
    : "${WS_KEEP_PATTERNS:=$WS_COPY_PATTERNS}"
    export WS_CONFIG_DIR
}

# Per-worktree state outside version control: exports for sub workspaces (API URL, slot) and the "setup done" marker.
ws_state() { echo "$(git -C "$1" rev-parse --absolute-git-dir)/workspace.env"; }

# Folder in the main checkout's git dir holding one manifest per workspace (<name>.env) and the orchestrator's files.
# Herdr has no parent/child worktrees, so the manifest is what ties a workspace together:
#   branch=…  main=<path>  main_ws=<herdr workspace id>  sub=<path>|<herdr workspace id> (repeated)
ws_dir() { echo "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/herdr-workspace"; }

# Manifest value(s) of key $3 in workspace $2 of the repo at $1.
ws_get() { sed -n "s/^$3=//p" "$(ws_dir "$1")/$2.env" 2>/dev/null; }

# Name of the workspace whose main (or sub) worktree is $2, looked up in the manifests of repo $1.
ws_name_of() {
    local f
    for f in "$(ws_dir "$1")"/*.env; do
        [[ -f "$f" ]] || continue
        if grep -qE "^(main=|sub=)$2(\||$)" "$f"; then basename "$f" .env; return; fi
    done
}

# Sub worktree paths of workspace $2 (manifest of the main checkout $1).
ws_children() { ws_get "$1" "$2" sub | cut -d'|' -f1; }

# Main worktree path of the workspace the sub worktree $2 belongs to (manifests of $1's repo); empty = none.
ws_parent_of() {
    local f
    for f in "$(ws_dir "$1")"/*.env; do
        [[ -f "$f" ]] || continue
        if grep -qE "^sub=$2(\||$)" "$f"; then sed -n 's/^main=//p' "$f"; return; fi
    done
}

# Herdr workspace id of the workspace showing the checkout $1 (empty = none open).
ws_wsid() {
    herdr workspace list | jq -r --arg p "$1" \
        '.result.workspaces[] | select(.worktree.checkout_path == $p) | .workspace_id' | head -1
}

# Main checkout path of a repo given as a path, or a folder name next to the main project / in its parent folder.
ws_repo_path() {
    local p=$1
    [[ -d "$p" ]] || p="$(dirname "$WS_MAIN_PROJECT")/$1"
    [[ -d "$p" ]] || { echo "Repo $1 not found (path, or folder next to the main project)." >&2; return 1; }
    ws_main "$p"
}

# Short agent-name part from a workspace name: lowercase [a-z0-9-], max 14 chars.
ws_slug() { echo "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n-' '-' | sed 's/^-*//; s/-*$//' | cut -c1-14 | sed 's/-*$//'; }

# Native agent arguments for kind $1, model $2, effort $3, extra args $4 (printed one per line).
ws_agent_args() {
    local kind=$1 model=$2 effort=$3 extra=$4 a
    if [[ -n "$model" ]]; then
        case $kind in
            claude) echo --model; echo "$model"; [[ -z "$effort" ]] || { echo --effort; echo "$effort"; } ;;
            codex) echo -m; echo "$model"; [[ -z "$effort" ]] || { echo -c; echo "model_reasoning_effort=\"$effort\""; } ;;
            *) echo --model; echo "$model" ;;
        esac
    fi
    for a in $extra; do echo "$a"; done
}

# Folder Herdr puts worktrees in: [worktrees] directory of config.toml, default ~/.herdr/worktrees.
ws_worktree_base() {
    local d
    d=$(sed -n '/^\[worktrees\]/,/^\[/{s/^ *directory *= *"\(.*\)".*/\1/p}' "${HERDR_CONFIG_PATH:-$HOME/.config/herdr/config.toml}" 2>/dev/null | head -1)
    d=${d:-$HOME/.herdr/worktrees}
    echo "${d/#\~/$HOME}"
}
