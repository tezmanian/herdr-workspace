#!/usr/bin/env bash
# Creates a workspace, or completes an existing one: main worktree on <branch> (existing branch is checked out with git and opened, otherwise
# created from the base branch), one worktree per sub repo, the setup in a "setup" tab per worktree, and an
# orchestrator agent in the main workspace. Run it inside Herdr, in the main checkout.
# Usage: ws-start.sh <branch> [--name N] [--ticket KEY] [--brief TEXT] [--breaks STEPS|none]
#   [--review on|off] [--autonomous on|off] [--sub REPO]... [--no-orchestrator | --orchestrator]
# REPO is a path or the folder name of a repo next to the main project. Rerun with more --sub to add sub workspaces
# later; rerun with --orchestrator to start a new orchestrator for an existing workspace (the old one crashed or was
# closed); it takes over.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
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
test "${HERDR_ENV:-}" = 1 || { echo "Not running inside Herdr (HERDR_ENV=1 missing)."; exit 1; }
MAIN=$(ws_main .)
WS_MAIN_PROJECT=$MAIN
ws_config "$MAIN"
((${#SUBS[@]})) || read -ra SUBS <<<"$WS_SUBS"
NAME=${NAME:-${TICKET:-${BRANCH//\//-}}}
DIR=$(ws_dir "$MAIN")
MANIFEST=$DIR/$NAME.env
mkdir -p "$DIR/$NAME"

# Creates (or opens) the worktree of repo $1 on BRANCH, runs its setup in a "setup" tab; prints "path|workspace id|root pane".
ensure_worktree() {
    local repo=$1 parent=${2:-} out path ws pane tab
    ws_config "$repo"
    if git -C "$repo" rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null \
        || git -C "$repo" rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null; then
        # Existing branch: herdr can only create new ones, so check it out with git and let herdr open that worktree.
        path=$(ws_worktree_base)/$(basename "$repo")/$NAME
        git -C "$repo" worktree add -q "$path" "$BRANCH" >&2
        out=$(herdr worktree open --cwd "$repo" --path "$path" --label "$NAME" --no-focus)
    else
        out=$(herdr worktree create --cwd "$repo" --branch "$BRANCH" --base "$WS_BASE_BRANCH" --label "$NAME" --no-focus)
    fi
    path=$(jq -r '.result.worktree.path' <<<"$out")
    ws=$(jq -r '.result.workspace.workspace_id' <<<"$out")
    pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")
    tab=$(herdr tab create --workspace "$ws" --cwd "$path" --label setup --no-focus)
    herdr pane run "$(jq -r '.result.root_pane.pane_id' <<<"$tab")" \
        "${parent:+WS_PARENT='$parent' }'$WS_HOME/scripts/ws-setup.sh'" >/dev/null
    echo "$path|$ws|$pane"
}

EXISTED=""; [[ ! -f "$MANIFEST" ]] || EXISTED=1
if [[ -z "$EXISTED" ]]; then
    IFS='|' read -r ROOT ROOT_WS ROOT_PANE <<<"$(ensure_worktree "$MAIN")"
    printf 'branch=%s\nmain=%s\nmain_ws=%s\nmain_pane=%s\nticket=%s\n' "$BRANCH" "$ROOT" "$ROOT_WS" "$ROOT_PANE" "$TICKET" > "$MANIFEST"
else
    ROOT=$(ws_get "$MAIN" "$NAME" main); ROOT_WS=$(ws_get "$MAIN" "$NAME" main_ws); ROOT_PANE=$(ws_get "$MAIN" "$NAME" main_pane)
fi
echo "main: $ROOT"
for s in ${SUBS[@]+"${SUBS[@]}"}; do
    repo=$(ws_repo_path "$s")
    if ws_get "$MAIN" "$NAME" sub | cut -d'|' -f1 | grep -qx "$(ws_main "$repo")"; then continue; fi
    IFS='|' read -r p w _ <<<"$(ensure_worktree "$repo" "$ROOT")"
    echo "sub=$p|$w" >> "$MANIFEST"
    echo "sub:  $p"
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
Workspace: $NAME, Branch: $BRANCH, Main worktree: $ROOT, Herdr workspace: $ROOT_WS
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
# A takeover must not collide with the old orchestrator's name.
ORCH=orch-$SLUG; ! herdr agent get "$ORCH" >/dev/null 2>&1 || ORCH=$ORCH-2
mapfile -t ARGS < <(ws_agent_args "$WS_ORCHESTRATOR_AGENT" "$WS_ORCHESTRATOR_MODEL" "$WS_ORCHESTRATOR_EFFORT" "$WS_ORCHESTRATOR_ARGS")
for _ in $(seq 10); do   # the root shell needs a moment before it takes a command
    herdr agent start "$ORCH" --kind "$WS_ORCHESTRATOR_AGENT" --pane "$ROOT_PANE" ${ARGS[@]+-- "${ARGS[@]}"} >/dev/null 2>&1 && break
    sleep 2
done
# A fresh worktree makes the agent ask whether to trust the folder (blocked): that is the user's call, so wait for it.
if ! herdr agent prompt "$ORCH" "$PROMPT" >/dev/null 2>&1; then
    echo "Orchestrator $ORCH waits for your input (e.g. 'trust this folder'): answer it in Herdr workspace $ROOT_WS. Waiting up to 10 min…"
    herdr agent wait "$ORCH" --until idle --timeout 600000 >/dev/null
    herdr agent prompt "$ORCH" "$PROMPT" >/dev/null
fi
echo "orchestrator: $ORCH (workspace $ROOT_WS)"
