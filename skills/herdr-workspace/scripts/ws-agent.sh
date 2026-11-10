#!/usr/bin/env bash
# Agents (workers) of a workspace, the same on both backends (Herdr 1 panes, herdr-core terminals).
#   ws-agent.sh start <name> --cwd DIR [--kind K] [--model M] [--effort E] [--args "…"] [--ws WORKSPACE] [--no-wait]
#   ws-agent.sh prompt <name> <text> [--wait] [--timeout SEC]   # waits until the agent is idle first
#   ws-agent.sh state <name>      # idle | working | blocked | done | error | unknown | gone
#   ws-agent.sh wait <name> [--timeout SEC]   # until it stops working (or blocks); prints the state
#   ws-agent.sh read <name> [lines]
#   ws-agent.sh list [prefix]     # "name state" per line
#   ws-agent.sh focus <name> | notify <title> [body]
# Names: [a-z][a-z0-9_-]{0,31}. Workers outlive this command (and, with core, an ended ssh link or parent agent).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
BE=$WS_BACKEND
[[ "$BE" != none ]] || { echo "No backend: run inside Herdr (HERDR_ENV=1) or start herdr-core (hc server status)." >&2; exit 1; }
CMD=${1:?usage: ws-agent.sh start|prompt|state|wait|read|list|focus|notify …}
shift

# Builds OPTS for prompt/wait: --wait, --timeout in the unit of the backend (herdr ms, core s).
build_opts() {
    OPTS=()
    [[ $WAIT != 1 ]] || OPTS+=(--wait)
    if ((TIMEOUT > 0)); then
        if [[ $BE == herdr ]]; then OPTS+=(--timeout "$((TIMEOUT * 1000))"); else OPTS+=(--timeout "$TIMEOUT"); fi
    fi
}

case $CMD in
    start)
        NAME=${1:?name}; shift
        CWD="" KIND=claude MODEL="" EFFORT="" EXTRA="" WSN="" WAIT=1
        while (($#)); do
            case $1 in
                --cwd) CWD=$2; shift 2 ;; --kind) KIND=$2; shift 2 ;; --model) MODEL=$2; shift 2 ;;
                --effort) EFFORT=$2; shift 2 ;; --args) EXTRA=$2; shift 2 ;; --ws) WSN=$2; shift 2 ;;
                --no-wait) WAIT=0; shift ;; *) echo "Unknown option $1"; exit 1 ;;
            esac
        done
        [[ -d "$CWD" ]] || { echo "--cwd DIR required"; exit 1; }
        ARGS=()
        while IFS= read -r a; do ARGS+=("$a"); done < <(ws_agent_args "$KIND" "$MODEL" "$EFFORT" "$EXTRA")
        if [[ $BE == herdr ]]; then
            WSID=$(ws_wsid "$CWD"); [[ -n "$WSID" ]] || { echo "No Herdr workspace shows $CWD."; exit 1; }
            PANES=$(herdr pane list --workspace "$WSID" | jq -c '.result.panes')
            LAST=$(jq -r '.[-1].pane_id' <<<"$PANES")
            DIR=right; (($(jq length <<<"$PANES") % 2 == 1)) || DIR=down
            PANE=$(herdr pane split "$LAST" --direction "$DIR" --cwd "$CWD" --no-focus | jq -r '.result.pane.pane_id')
            # agent_not_ready (e.g. the trust dialog) keeps the name; be_wait_idle below deals with it. Other errors stop here.
            OUT=$(herdr agent start "$NAME" --kind "$KIND" --pane "$PANE" ${ARGS[@]+-- "${ARGS[@]}"} 2>&1) \
                || [[ "$OUT" == *agent_not_ready* ]] || { echo "$OUT" >&2; exit 1; }
        else
            hc run --bg --no-parent --keep --name "$NAME" --cwd "$CWD" ${WSN:+--label "ws=$WSN"} --label "role=$NAME" \
                "$KIND" ${ARGS[@]+"${ARGS[@]}"} >/dev/null
        fi
        [[ $WAIT == 0 ]] || be_wait_idle "$NAME" 600
        echo "$NAME started ($BE)" ;;
    prompt)
        NAME=${1:?name}; TEXT=${2:?text}; shift 2
        WAIT=0 TIMEOUT=0
        while (($#)); do
            case $1 in --wait) WAIT=1; shift ;; --timeout) TIMEOUT=$2; shift 2 ;; *) echo "Unknown option $1"; exit 1 ;; esac
        done
        [[ "$TEXT" != -* ]] || TEXT=" $TEXT"   # a text starting with - must not be read as an option
        build_opts
        be_wait_idle "$NAME" 600
        if [[ $BE == herdr ]]; then herdr agent prompt "$NAME" "$TEXT" ${OPTS[@]+"${OPTS[@]}"} >/dev/null || [[ $WAIT == 1 ]]
        else hc send "$NAME" "$TEXT" ${OPTS[@]+"${OPTS[@]}"} >/dev/null || [[ $WAIT == 1 ]]; fi
        [[ $WAIT == 0 ]] || be_state "$NAME" ;;
    state) be_state "${1:?name}" ;;
    wait)
        NAME=${1:?name}; shift
        WAIT=0 TIMEOUT=0
        while (($#)); do case $1 in --timeout) TIMEOUT=$2; shift 2 ;; *) echo "Unknown option $1"; exit 1 ;; esac; done
        build_opts
        if [[ $BE == herdr ]]; then herdr agent wait "$NAME" ${OPTS[@]+"${OPTS[@]}"} >/dev/null || true
        else hc wait "$NAME" ${OPTS[@]+"${OPTS[@]}"} >/dev/null || true; fi
        be_state "$NAME" ;;
    read)
        NAME=${1:?name}; LINES_=${2:-80}
        if [[ $BE == herdr ]]; then herdr agent read "$NAME" --source recent-unwrapped --lines "$LINES_"
        else hc read "$NAME" | tail -n "$LINES_"; fi ;;
    list)
        PREFIX=${1:-}
        if [[ $BE == herdr ]]; then names=$(herdr agent list | jq -r --arg p "$PREFIX" '.result.agents[] | select(.name != null and (.name | startswith($p))) | .name')
        else names=$(hc ls --json | jq -r --arg p "$PREFIX" '.terminals[] | select(.name != null and (.name | startswith($p))) | .name'); fi
        for n in $names; do echo "$n $(be_state "$n")"; done ;;
    focus)
        if [[ $BE == herdr ]]; then herdr agent focus "${1:?name}" >/dev/null; else echo "Attach with: hc attach $1"; fi ;;
    notify)
        if [[ $BE == herdr ]]; then herdr notification show "${1:?title}" ${2:+--body "$2"} --sound request >/dev/null
        else echo "NOTIFY: $1${2:+ — $2}" >&2; ! command -v notify-send >/dev/null || notify-send "$1" "${2:-}" || true; fi ;;
    *) echo "Unknown command $CMD"; exit 1 ;;
esac
