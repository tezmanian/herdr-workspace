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
    [[ "$(ws_backend)" == herdr ]] || return 0
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

# ---------------------------------------------------------------------------------------------------------------
# Backends. "herdr": Herdr 1 (workspaces, panes, `herdr agent`). "core": herdr-core's `hc` (terminals that stay alive,
# also on remote machines). WS_BACKEND=herdr|core forces one; default herdr inside a Herdr pane, else core.
# ---------------------------------------------------------------------------------------------------------------
ws_backend() {
    if [[ -n "${WS_BACKEND:-}" ]]; then echo "$WS_BACKEND"
    elif [[ "${HERDR_ENV:-}" == 1 ]] && command -v herdr >/dev/null && herdr workspace list >/dev/null 2>&1; then echo herdr
    elif command -v hc >/dev/null && hc server status >/dev/null 2>&1; then echo core
    else echo none; fi
}

# Run a script of this skill on another machine (hc machine ls) when the args carry `--on <machine>` [--remote-dir D].
# Call first, as: ws_remote "$@". Terminals started there keep running when this command or the ssh link ends.
# The skills must be installed there too (install.sh); WS_REMOTE_SCRIPTS overrides their path on that machine.
ws_remote() {
    local a=("$@") i M="" D=$PWD out=()
    for ((i = 0; i < ${#a[@]}; i++)); do
        case ${a[i]} in
            --on) M=${a[++i]} ;;
            --remote-dir) D=${a[++i]} ;;
            *) out+=("${a[i]}") ;;
        esac
    done
    [[ -z "$M" ]] && return 0
    exec hc exec --on "$M" --cwd "$D" --timeout 600 bash -lc \
        'exec "${WS_REMOTE_SCRIPTS:-$HOME/.claude/skills/herdr-workspace/scripts}/$0" "$@"' "$(basename "$0")" "${out[@]}"
}

# be_worktree <repo> <branch> <name> <base>: creates or checks out the worktree, prints "path|workspace id|root pane".
be_worktree() {
    local repo=$1 branch=$2 name=$3 base=$4 path out
    path=$(ws_worktree_base)/$(basename "$repo")/$name
    case $(ws_backend) in
        herdr)
            if git -C "$repo" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
                || git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
                # Existing branch: herdr can only create new ones, so check it out with git and let herdr open that worktree.
                git -C "$repo" worktree add -q "$path" "$branch" >&2
                out=$(herdr worktree open --cwd "$repo" --path "$path" --label "$name" --no-focus)
            else
                out=$(herdr worktree create --cwd "$repo" --branch "$branch" --base "$base" --label "$name" --no-focus)
            fi
            echo "$(jq -r '.result.worktree.path' <<<"$out")|$(jq -r '.result.workspace.workspace_id' <<<"$out")|$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")" ;;
        core)
            if git -C "$repo" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
                || git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
                git -C "$repo" worktree add -q "$path" "$branch" >&2
            else
                git -C "$repo" worktree add -q -b "$branch" "$path" "$base" >&2
            fi
            echo "$path||" ;;
        *) echo "No backend: run inside Herdr (HERDR_ENV=1) or start herdr-core (hc server status)." >&2; return 1 ;;
    esac
}

# be_setup <workspace name> <worktree> <workspace id> [parent worktree]: runs ws-setup.sh for the worktree in the background.
be_setup() {
    local name=$1 wt=$2 wsid=$3 parent=${4:-} tab
    case $(ws_backend) in
        herdr)
            tab=$(herdr tab create --workspace "$wsid" --cwd "$wt" --label setup --no-focus)
            herdr pane run "$(jq -r '.result.root_pane.pane_id' <<<"$tab")" \
                "${parent:+WS_PARENT='$parent' }'$WS_HOME/scripts/ws-setup.sh'" >/dev/null ;;
        core)
            hc run --bg --no-parent --name "su-$(ws_slug "$name")-$(ws_slug "$(basename "$(ws_main "$wt")")" | cut -c1-9)" --cwd "$wt" \
                --label "ws=$name" --label role=setup \
                env ${parent:+"WS_PARENT=$parent"} "$WS_HOME/scripts/ws-setup.sh" >/dev/null ;;
    esac
}

# be_state <agent>: idle | working | blocked | done | error | unknown | gone
be_state() {
    case $(ws_backend) in
        herdr) herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' || echo gone ;;
        core) hc get "$1" --json 2>/dev/null | jq -r '.status.state // "unknown"' || echo gone ;;
    esac
}

# be_wait_idle <agent> [seconds]: until the agent can take input. A fresh folder makes Claude ask "trust this folder":
# that is the user's call (herdr: blocked, core: no status yet), so say so and keep waiting.
be_wait_idle() {
    local name=$1 max=${2:-600} t=0 s said=0
    while ((t <= max)); do
        s=$(be_state "$name")
        case $s in idle | done) return 0 ;; gone) echo "Agent $name is gone." >&2; return 1 ;; esac
        if ((t >= 10 && said == 0)); then
            echo "Agent $name is $s: it may wait for your input (e.g. 'trust this folder'). Answer it yourself (herdr agent focus $name / hc attach $name). Waiting up to $((max / 60)) min…" >&2
            said=1
        fi
        sleep 3
        t=$((t + 3))
    done
    echo "Agent $name did not become idle within $max s (state: $s)." >&2
    return 1
}

# be_kill_dir <path>: ends every core terminal working in that worktree (setup logs, agents, shells).
be_kill_dir() {
    [[ "$(ws_backend)" == core ]] || return 0
    local a
    for a in $(hc ls --all --json | jq -r --arg p "$1" '.terminals[] | select(.cwd == $p or (.cwd | startswith($p + "/"))) | .address'); do
        hc kill "$a" >/dev/null 2>&1 || true
        hc rm "$a" >/dev/null 2>&1 || true
    done
}
