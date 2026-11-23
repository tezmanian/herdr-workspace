#!/usr/bin/env bash
# Creates a workspace, or completes an existing one: main worktree on <branch> (existing branch is checked out,
# otherwise created from the base branch), one worktree per sub repo, each one's setup running in the background, and
# an orchestrator agent in the main worktree. Run it in the main checkout, inside Herdr or with herdr-core running.
# Usage: ws-start.sh <branch> [--name N] [--ticket KEY] [--brief TEXT] [--breaks STEPS|none]
#   [--review on|off] [--autonomous on|off] [--sub REPO]... [--no-orchestrator | --orchestrator]
#   [--on MACHINE --remote-dir DIR]
# The workspace name is --name, else the ticket key, else the branch with / as - (letters, digits, . _ - only).
# REPO is a path or the folder name of a repo next to the main project; without --sub a new workspace gets WS_SUBS.
# Rerun for an existing workspace (same branch and name) with --sub to add sub workspaces (WS_SUBS is not applied
# again, so a removed sub stays removed), or with --orchestrator to start a new orchestrator (the old one crashed or
# was closed); it takes over. --no-orchestrator: worktrees only. --on runs it on a saved herdr-core machine
# (hc machine ls); the work there keeps running.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ws_help "$@"
ws_remote "$@"
BRANCH=${1:?usage: ws-start.sh <branch> [--name N] [--ticket KEY] [--brief TEXT] [--breaks S] [--review on|off] [--autonomous on|off] [--sub REPO]... [--no-orchestrator|--orchestrator]   (--help for more)}
[[ "$BRANCH" != -* ]] || { echo "The first argument is the branch, not an option ($BRANCH); see --help." >&2; exit 1; }
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
        *) echo "Unknown option $1 (see --help)" >&2; exit 1 ;;
    esac
done
[[ "$WS_BACKEND" != none ]] || { echo "No backend: run inside Herdr (HERDR_ENV=1) or start herdr-core (hc server status)." >&2; exit 1; }
MAIN=$(ws_main .)
WS_MAIN_PROJECT=$MAIN
ws_config "$MAIN"
NAME=${NAME:-${TICKET:-${BRANCH//\//-}}}
ws_check_name "$NAME"
DIR=$(ws_dir "$MAIN")
MANIFEST=$DIR/$NAME.env
EXISTED=""; [[ ! -f "$MANIFEST" ]] || EXISTED=1
if [[ -n "$EXISTED" ]]; then
    HAVE=$(ws_get "$MAIN" "$NAME" branch)
    [[ "$HAVE" == "$BRANCH" ]] || { echo "Workspace $NAME exists on branch $HAVE, not $BRANCH: rerun with that branch, or pick another --name." >&2; exit 1; }
elif ((${#SUBS[@]} == 0)); then
    read -ra SUBS <<<"$WS_SUBS" || true   # the default sub repos are for a new workspace only
fi

# Creates (or checks out) the worktree of repo $1 on BRANCH: sets WT_OUT ("path|workspace id"), WT_PATH, WT_ID.
# The caller writes the manifest entry before it starts the setup, so a worktree is never left without one
# (ws-status.sh shows it, ws-stop.sh removes it) when a later step fails.
make_worktree() {
    ws_config "$1"
    WT_OUT=$(be_worktree "$1" "$BRANCH" "$NAME" "$WS_BASE_BRANCH")
    IFS='|' read -r WT_PATH WT_ID <<<"$WT_OUT"
    [[ -n "$WT_PATH" && "$WT_PATH" != null ]] || { echo "Could not create the worktree for $1." >&2; exit 1; }
}

if [[ -z "$EXISTED" ]]; then
    make_worktree "$MAIN"
    ROOT=$WT_PATH ROOT_WS=$WT_ID
    mkdir -p "$DIR/$NAME"
    printf 'branch=%s\nmain=%s\nmain_ws=%s\nticket=%s\n' "$BRANCH" "$ROOT" "$ROOT_WS" "$TICKET" > "$MANIFEST"
    be_setup "$NAME" "$ROOT" "$ROOT_WS"
else
    ROOT=$(ws_get "$MAIN" "$NAME" main); ROOT_WS=$(ws_get "$MAIN" "$NAME" main_ws)
fi
echo "main: $ROOT"
for s in ${SUBS[@]+"${SUBS[@]}"}; do
    repo=$(ws_repo_path "$s")
    have=0
    while IFS= read -r c; do
        [[ -z "$c" || ! -d "$c" || "$(ws_main "$c")" != "$repo" ]] || have=1
    done < <(ws_children "$MAIN" "$NAME")
    if ((have)); then echo "sub:  $s already in the workspace"; continue; fi
    make_worktree "$repo"
    echo "sub=$WT_OUT" >> "$MANIFEST"
    be_setup "$NAME" "$WT_PATH" "$WT_ID" "$ROOT"
    echo "sub:  $WT_PATH"
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
# Either way that happens in the background, so this command returns at once: with core as its own terminal (it also
# survives a closed ssh link), with Herdr 1 as a detached process that logs into the workspace files folder.
if [[ "$WS_BACKEND" == core ]]; then
    ws_env_args
    hc run --bg --no-parent --rm --name "dl-$SLUG" --cwd "$ROOT" --label "ws=$NAME" \
        env ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} "$WS_HOME/scripts/ws-agent.sh" prompt "$ORCH" "$PROMPT" >/dev/null
    echo "orchestrator: $ORCH (prompt follows once it is idle; if it asks for the folder trust: hc attach $ORCH)"
else
    nohup "$WS_HOME/scripts/ws-agent.sh" prompt "$ORCH" "$PROMPT" >"$DIR/$NAME/orchestrator-prompt.log" 2>&1 </dev/null &
    echo "orchestrator: $ORCH (workspace $ROOT_WS; prompt follows once it is idle; if it asks for the folder trust, confirm it in its pane; log: $DIR/$NAME/orchestrator-prompt.log)"
fi
