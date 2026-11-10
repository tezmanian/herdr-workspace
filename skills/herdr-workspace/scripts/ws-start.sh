#!/usr/bin/env bash
# Creates a workspace, or completes an existing one: main worktree on <branch> (existing branch is checked out,
# otherwise created from the base branch), one worktree per sub repo, each one's setup running in the background, and
# an orchestrator agent in the main worktree. Run it in the main checkout, inside Herdr or with herdr-core running.
# Usage: ws-start.sh <branch> [--name N] [--ticket KEY] [--brief TEXT] [--breaks STEPS|none]
#   [--review on|off] [--autonomous on|off] [--sub REPO]... [--no-orchestrator | --orchestrator]
#   [--on MACHINE --remote-dir DIR]
# REPO is a path or the folder name of a repo next to the main project. Rerun with more --sub to add sub workspaces
# later; rerun with --orchestrator to start a new orchestrator for an existing workspace (the old one crashed or was
# closed); it takes over. --on runs it on a saved herdr-core machine (hc machine ls); the work there keeps running.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ws_remote "$@"
BRANCH=${1:?usage: ws-start.sh <branch> [--name N] [--ticket KEY] [--brief TEXT] [--breaks S] [--review on|off] [--autonomous on|off] [--sub REPO]... [--no-orchestrator|--orchestrator]}
shift
NAME="" TICKET="" BRIEF="" BREAKS="" REVIEW="" AUTONOMY="" ORCHESTRATOR=1
SUBS=()
while (($#)); do
    case $1 in
        --name) NAME=$2; shift 2 ;;
        --ticket) TICKET=$2; shift 2 ;;
        --brief) BRIEF=$2; shift 2 ;;
        --breaks) BREAKS=$2; shift 2 ;;
        --review) REVIEW=$2; shift 2 ;;
        --autonomous) AUTONOMY=$2; shift 2 ;;
        --sub) SUBS+=("$2"); shift 2 ;;
        --no-orchestrator) ORCHESTRATOR=0; shift ;;
        --orchestrator) ORCHESTRATOR=2; shift ;;
        *) echo "Unknown option $1"; exit 1 ;;
    esac
done
[[ "$WS_BACKEND" != none ]] || { echo "No backend: run inside Herdr (HERDR_ENV=1) or start herdr-core (hc server status)."; exit 1; }
MAIN=$(ws_main .)
WS_MAIN_PROJECT=$MAIN
ws_config "$MAIN"
((${#SUBS[@]})) || read -ra SUBS <<<"$WS_SUBS" || true
NAME=${NAME:-${TICKET:-${BRANCH//\//-}}}
DIR=$(ws_dir "$MAIN")
MANIFEST=$DIR/$NAME.env

# Creates (or checks out) the worktree of repo $1 on BRANCH and starts its setup; prints "path|workspace id".
# Assigns before reading, so a failure stops the script instead of leaving an empty manifest entry.
ensure_worktree() {
    local repo=$1 parent=${2:-} out path ws
    ws_config "$repo"
    out=$(be_worktree "$repo" "$BRANCH" "$NAME" "$WS_BASE_BRANCH")
    IFS='|' read -r path ws <<<"$out"
    [[ -n "$path" ]] || { echo "Could not create the worktree for $repo." >&2; return 1; }
    be_setup "$NAME" "$path" "$ws" "$parent"
    echo "$out"
}

EXISTED=""; [[ ! -f "$MANIFEST" ]] || EXISTED=1
if [[ -z "$EXISTED" ]]; then
    out=$(ensure_worktree "$MAIN")
    IFS='|' read -r ROOT ROOT_WS <<<"$out"
    mkdir -p "$DIR/$NAME"
    printf 'branch=%s\nmain=%s\nmain_ws=%s\nticket=%s\n' "$BRANCH" "$ROOT" "$ROOT_WS" "$TICKET" > "$MANIFEST"
else
    ROOT=$(ws_get "$MAIN" "$NAME" main); ROOT_WS=$(ws_get "$MAIN" "$NAME" main_ws)
fi
echo "main: $ROOT"
for s in ${SUBS[@]+"${SUBS[@]}"}; do
    repo=$(ws_repo_path "$s")
    have=0
    for c in $(ws_children "$MAIN" "$NAME"); do
        [[ ! -d "$c" || "$(ws_main "$c")" != "$repo" ]] || have=1
    done
    if ((have)); then echo "sub:  $s already in the workspace"; continue; fi
    out=$(ensure_worktree "$repo" "$ROOT")
    echo "sub=$out" >> "$MANIFEST"
    echo "sub:  ${out%%|*}"
done

# New workspace: start the orchestrator unless --no-orchestrator; existing one: only with --orchestrator (resume).
if [[ -n "$EXISTED" ]]; then
    [[ "$ORCHESTRATOR" == 2 ]] || exit 0
    START="resume: take over the work of this workspace (skill herdr-orchestrator, section Resume)"
else
    [[ "$ORCHESTRATOR" != 0 ]] || exit 0
    START="new"
fi
ws_config "$MAIN"
[[ -n "$TICKET" ]] || TICKET=$(ws_get "$MAIN" "$NAME" ticket)
CONFIG=${WS_CONFIG_DIR:+$WS_CONFIG_DIR/workspace.env}
SLUG=$(ws_slug "$NAME")
PROMPT="You are the orchestrator of this workspace. Load the skill herdr-orchestrator first.
Start: $START
Workspace: $NAME, Branch: $BRANCH, Main worktree: $ROOT, Herdr workspace: ${ROOT_WS:-none}
Sub worktrees: $(ws_get "$MAIN" "$NAME" sub | tr '\n' ' ')   (path|herdr workspace id)
Name slug: $SLUG (agent names: $SLUG-plan, $SLUG-impl-<repo>, $SLUG-review-<repo>, $SLUG-decider)
Workspace files: $DIR/$NAME/ (reports, decisions)
Ticket: ${TICKET:-none}
Task: ${BRIEF:-see ticket}
Config: ${CONFIG:-none}
Plan mode: $WS_PLAN
Breaks: ${BREAKS:-${WS_PLAN_BREAKS:-none}}
Review: ${REVIEW:-${WS_REVIEW:-off}}
Autonomous: ${AUTONOMY:-${WS_AUTONOMY:-off}}"
# A takeover must not collide with a name that is still alive.
ORCH=orch-$SLUG; n=1
while [[ "$("$WS_HOME/scripts/ws-agent.sh" state "$ORCH")" != gone ]]; do n=$((n + 1)); ORCH=orch-$SLUG-$n; done
"$WS_HOME/scripts/ws-agent.sh" start "$ORCH" --cwd "$ROOT" --kind "$WS_ORCHESTRATOR_AGENT" --model "$WS_ORCHESTRATOR_MODEL" \
    --effort "$WS_ORCHESTRATOR_EFFORT" --args "$WS_ORCHESTRATOR_ARGS" --ws "$NAME" --no-wait
# The prompt is sent once the agent takes input (a fresh folder first asks "trust this folder": the user's call).
# With core that runs as its own background terminal, so it also survives a closed ssh link.
if [[ "$WS_BACKEND" == core ]]; then
    hc run --bg --no-parent --rm --name "dl-$SLUG" --cwd "$ROOT" --label "ws=$NAME" \
        "$WS_HOME/scripts/ws-agent.sh" prompt "$ORCH" "$PROMPT" >/dev/null
    echo "orchestrator: $ORCH (prompt follows once it is idle; if it asks for the folder trust: hc attach $ORCH)"
else
    "$WS_HOME/scripts/ws-agent.sh" prompt "$ORCH" "$PROMPT"
    echo "orchestrator: $ORCH (workspace $ROOT_WS)"
fi
