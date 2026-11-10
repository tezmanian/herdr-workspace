# Shared helpers for the herdr-workspace scripts (sourced). Works with bash 3.2 (macOS) and up.
shopt -s inherit_errexit 2>/dev/null || true   # bash 4.4+: a failing command inside $(...) stops the script
WS_HOME=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# User-level configs for repos that should not carry their own.
WS_USER_HOME=${HERDR_WORKSPACE_HOME:-$HOME/.config/herdr-workspace}

# Main checkout of the repository containing $1.
ws_main() { git -C "$1" worktree list --porcelain | sed -n '1s/^worktree //p'; }

# Loads the first config found for the repo at $1 (main checkout):
# <repo>/.herdr/workspace/, <repo>/.agents/workspace/, $HERDR_WORKSPACE_HOME/projects/<repo dir name>/ (file workspace.env).
# Only keys the scripts use get defaults here; the others (skills, briefs, roles …) are read by the orchestrator agent.
ws_config() {
    WS_BASE_BRANCH=master WS_SUBS="" WS_PLAN=worker WS_PLAN_BREAKS="" WS_REVIEW=off WS_AUTONOMY=off WS_IGNORED_ON_REMOVE=ask
    WS_COPY="" WS_COPY_PATTERNS="" WS_COPY_EXCLUDE="" WS_CLONE="" WS_KEEP="" WS_KEEP_PATTERNS=""
    WS_SETUP="" WS_TEARDOWN=""
    WS_ORCHESTRATOR_AGENT=claude WS_ORCHESTRATOR_MODEL="" WS_ORCHESTRATOR_EFFORT="" WS_ORCHESTRATOR_ARGS=""
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

# Per-worktree state outside version control: exports for sub workspaces (API URL, slot) and the "setup done" marker
# (a failed setup leaves workspace.env.failed instead, so waiting subs stop).
ws_state() { echo "$(git -C "$1" rev-parse --absolute-git-dir)/workspace.env"; }

# Folder in the main checkout's git dir holding one manifest per workspace (<name>.env) and the orchestrator's files.
# Herdr has no parent/child worktrees, so the manifest is what ties a workspace together:
#   branch=…  main=<path>  main_ws=<herdr workspace id>  ticket=…  sub=<path>|<herdr workspace id> (repeated)
ws_dir() { echo "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/herdr-workspace"; }

# Manifest value(s) of key $3 in workspace $2 of the repo at $1.
ws_get() { sed -n "s/^$3=//p" "$(ws_dir "$1")/$2.env" 2>/dev/null || true; }

# Sub worktree paths of workspace $2 (manifest of the main checkout $1).
ws_children() { ws_get "$1" "$2" sub | cut -d'|' -f1; }

# Herdr workspace id of the workspace showing the checkout $1 (empty = none open, or not the Herdr backend).
ws_wsid() {
    [[ "$WS_BACKEND" == herdr ]] || return 0
    herdr workspace list | jq -r --arg p "$1" \
        '.result.workspaces[] | select(.worktree.checkout_path == $p) | .workspace_id' | head -1
}

# Main checkout path of a repo given as a path, or a folder name next to the main project ($WS_MAIN_PROJECT).
ws_repo_path() {
    local p=$1
    [[ -d "$p" ]] || p="$(dirname "$WS_MAIN_PROJECT")/$1"
    [[ -d "$p" ]] || { echo "Repo $1 not found (path, or folder next to the main project)." >&2; return 1; }
    ws_main "$p"
}

# Agent-name part from a workspace name: lowercase [a-z0-9-], starts with a letter, max 14 chars. A longer name is cut
# to 9 chars plus a 4-digit checksum, so two long names do not share a slug.
ws_slug() {
    local s
    s=$(echo "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n-' '-' | sed 's/^-*//; s/-*$//')
    [[ "$s" == [a-z]* ]] || s=w$s
    if ((${#s} > 14)); then s="$(echo "$s" | cut -c1-9 | sed 's/-*$//')-$(printf '%04x' $(($(printf '%s' "$1" | cksum | cut -d' ' -f1) % 65536)))"; fi
    echo "$s"
}

# Native agent arguments for kind $1, model $2, effort $3, extra args $4, one per line.
ws_agent_args() {
    local kind=$1 model=$2 effort=$3 extra=$4 a
    local -a words
    if [[ -n "$model" ]]; then
        case $kind in
            claude) printf '%s\n' --model "$model"; [[ -z "$effort" ]] || printf '%s\n' --effort "$effort" ;;
            codex) printf '%s\n' -m "$model"; [[ -z "$effort" ]] || printf '%s\n' -c "model_reasoning_effort=\"$effort\"" ;;
            *) printf '%s\n' --model "$model" ;;
        esac
    fi
    read -ra words <<<"$extra"   # read, not a bare $extra: no file globbing of the words
    for a in ${words[@]+"${words[@]}"}; do printf '%s\n' "$a"; done
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
ws_detect_backend() {
    if [[ "${HERDR_ENV:-}" == 1 ]] && command -v herdr >/dev/null && herdr workspace list >/dev/null 2>&1; then echo herdr
    elif command -v hc >/dev/null && hc server status >/dev/null 2>&1; then echo core
    else echo none; fi
}

# Run a script of this skill on another machine (hc machine ls) when the args carry `--on <machine> --remote-dir <repo>`.
# Call first, as: ws_remote "$@". Terminals started there keep running when this command or the ssh link ends.
# The skills must be installed there too (install.sh). hc exec ends a command after 10 minutes at most.
ws_remote() {
    local a=("$@") i M="" D="" out=()
    for ((i = 0; i < ${#a[@]}; i++)); do
        case ${a[i]} in
            --on | --remote-dir)
                ((i + 1 < ${#a[@]})) || { echo "${a[i]} needs a value." >&2; exit 1; }
                if [[ ${a[i]} == --on ]]; then M=${a[i + 1]}; else D=${a[i + 1]}; fi
                i=$((i + 1)) ;;
            *) out+=("${a[i]}") ;;
        esac
    done
    [[ -n "$M" ]] || return 0
    [[ -n "$D" ]] || { echo "--on $M needs --remote-dir <repo path on $M>." >&2; exit 1; }
    exec hc exec --on "$M" --cwd "$D" --timeout 600 bash -lc \
        'for d in "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex/skills"; do
             [[ -x "$d/herdr-workspace/scripts/$0" ]] && exec "$d/herdr-workspace/scripts/$0" "$@"
         done; echo "herdr-workspace skills not found on this machine (install.sh)" >&2; exit 1' \
        "$(basename "$0")" ${out[@]+"${out[@]}"}
}

# be_worktree <repo> <branch> <name> <base>: creates or checks out the worktree, prints "path|workspace id".
be_worktree() {
    local repo=$1 branch=$2 name=$3 base=$4 path out
    path=$(ws_worktree_base)/$(basename "$repo")/$name
    if git -C "$repo" rev-parse -q --verify "refs/heads/$branch" >/dev/null \
        || git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
        git -C "$repo" worktree add -q "$path" "$branch" >&2 || return 1   # existing branch: herdr only creates new ones
        [[ $WS_BACKEND != herdr ]] || out=$(herdr worktree open --cwd "$repo" --path "$path" --label "$name" --no-focus) || return 1
    elif [[ $WS_BACKEND == herdr ]]; then
        out=$(herdr worktree create --cwd "$repo" --branch "$branch" --base "$base" --label "$name" --no-focus) || return 1
    else
        git -C "$repo" worktree add -q -b "$branch" "$path" "$base" >&2 || return 1
    fi
    if [[ $WS_BACKEND == herdr ]]; then
        echo "$(jq -r '.result.worktree.path' <<<"$out")|$(jq -r '.result.workspace.workspace_id' <<<"$out")"
    else
        echo "$path|"
    fi
}

# be_setup <workspace name> <worktree> <workspace id> [parent worktree]: runs ws-setup.sh for the worktree in the background
# (Herdr 1: a "setup" tab; core: a terminal named su-…, kept after it finishes so its log can be read).
be_setup() {
    local name=$1 wt=$2 wsid=$3 parent=${4:-} tab
    if [[ $WS_BACKEND == herdr ]]; then
        tab=$(herdr tab create --workspace "$wsid" --cwd "$wt" --label setup --no-focus)
        herdr pane run "$(jq -r '.result.root_pane.pane_id' <<<"$tab")" \
            "$(printf 'WS_PARENT=%q %q' "$parent" "$WS_HOME/scripts/ws-setup.sh")" >/dev/null
    else
        hc run --bg --no-parent --name "su-$(ws_slug "$name")-$(ws_slug "$(basename "$(ws_main "$wt")")" | cut -c1-9)" --cwd "$wt" \
            --label "ws=$name" --label role=setup env "WS_PARENT=$parent" "$WS_HOME/scripts/ws-setup.sh" >/dev/null
    fi
}

# be_state <agent>: idle | working | blocked | done | error | unknown | gone
be_state() {
    if [[ $WS_BACKEND == herdr ]]; then herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' || echo gone
    else hc get "$1" --json 2>/dev/null | jq -r '.status.state // "unknown"' || echo gone; fi
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
    [[ $WS_BACKEND == core ]] || return 0
    local a
    for a in $(hc ls --all --json | jq -r --arg p "$1" '.terminals[] | select(.cwd == $p or (.cwd | startswith($p + "/"))) | .address'); do
        hc kill "$a" >/dev/null 2>&1 || true
        hc rm "$a" >/dev/null 2>&1 || true
    done
}

export WS_BACKEND=${WS_BACKEND:-$(ws_detect_backend)}   # once per run; child scripts inherit it
