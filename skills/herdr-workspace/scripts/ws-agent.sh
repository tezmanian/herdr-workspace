#!/usr/bin/env bash
# Agents (workers) of a workspace, the same on both backends (Herdr 1 panes, herdr-core terminals).
#   ws-agent.sh start <name> --cwd DIR [--kind K] [--model M] [--effort E] [--args "…"] [--ws WORKSPACE] [--no-wait]
#   ws-agent.sh prompt <name> <text> [--wait] [--timeout SEC] [--report FILE [--until-report]]
#                 # waits until the agent is idle first; with --report a turn that ends without a finished
#                 # report file prints "still-working" and exits 3 (--until-report keeps waiting; exit 4 = timeout)
#   ws-agent.sh wait-report <file> [--any FILE…] [--agent NAME]… [--timeout SEC] [--fresh]
#                 # until a file ends with REPORT/QUESTION; --agent: stop (exit 5) when that worker is blocked/gone
#   ws-agent.sh state <name>      # idle | working | blocked | done | error | unknown | gone
#   ws-agent.sh wait <name> [--timeout SEC]   # until it stops working (or blocks); prints the state
#   ws-agent.sh read <name> [lines]
#   ws-agent.sh list [prefix]     # "name state" per line (also registered workers whose name was lost)
#   ws-agent.sh stop <name>       # ends a worker for good (closes its pane / kills its terminal), e.g. to free a slot
#   ws-agent.sh stop-all <prefix> # the same for every live agent whose name starts with <prefix> (e.g. "<slug>-")
#   ws-agent.sh focus <name> | notify <title> [body]
# Names: [a-z][a-z0-9_-]{0,31}; with Herdr 1 a raw pane ID (w3:p2) works wherever a name is expected. Workers outlive
# this command (and, with core, an ended ssh link or parent agent).
# Registry: `start` records name -> terminal id in workers.tsv. With --ws it lies in the workspace files folder
# (<git-common-dir>/herdr-workspace/<ws>/), otherwise (or outside a repo) in ~/.local/state/herdr-workspace/<ws>/
# (HERDR_WORKSPACE_STATE moves that; FILES=<dir> in the environment forces a folder). A name that no longer resolves
# (e.g. after the orchestrator's /clear) falls back to it.
# Report waits (--until-report, wait-report) end after WS_REPORT_TIMEOUT seconds (default 1800) unless --timeout says
# otherwise; --timeout 0 waits without limit.
# Limits (main project's config; empty = none): WS_IMPLEMENT_MAX=N refuses `start` of a <slug>-impl-… worker (exit 6)
# while N implementers of that workspace are alive; WS_WORKERS_MAX=N does the same for all workers "<slug>-…" of the
# workspace given with --ws (planner, implementers, reviewers, decider; not the orchestrator). Reuse a worker
# (`prompt`) or `stop` a finished one first.
# Exit codes: 0 ok, 1 error (also: the prompt could not be sent), 3 prompt --report: turn ended without a finished
# report, 4 timeout, 5 agent blocked, in error or gone while waiting for a report, 6 worker limit reached.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ws_help "$@"
BE=$WS_BACKEND
CMD=${1:?usage: ws-agent.sh start|prompt|state|wait|wait-report|read|list|stop|stop-all|focus|notify …}
shift
[[ "$BE" != none || "$CMD" == wait-report ]] || { echo "No backend: run inside Herdr (HERDR_ENV=1) or start herdr-core (hc server status)." >&2; exit 1; }

# ---- registry: workers.tsv, one row per worker: name backend terminal-id pane cwd status(live|dead) started -------
REG_STATE=${HERDR_WORKSPACE_STATE:-$HOME/.local/state/herdr-workspace}
TAB=$'\t'
REPORT_TIMEOUT=${WS_REPORT_TIMEOUT:-1800}
is_num() { [[ "$1" =~ ^[0-9]+$ ]] || { echo "--timeout needs whole seconds, got '$1'." >&2; exit 1; }; }

# reg_write_file <workspace> <cwd>: the file start writes. $FILES if set; else the files folder of the workspace in
# the repo of <cwd> (it exists once ws-start.sh created the workspace); else the state folder.
reg_write_file() {
    local d
    if [[ -n "${FILES:-}" ]]; then echo "$FILES/workers.tsv"; return; fi
    if [[ -n "$1" ]] && d=$(ws_dir "$2" 2>/dev/null) && [[ -d "$d/$1" ]]; then echo "$d/$1/workers.tsv"; return; fi
    echo "$REG_STATE/${1:-default}/workers.tsv"
}
# reg_lock/reg_unlock <file>: one writer at a time (mkdir is atomic everywhere; a lock older than ~5 s is stale).
reg_lock() {
    local i=0
    until mkdir "$1.lock" 2>/dev/null; do
        i=$((i + 1))
        if ((i > 50)); then rmdir "$1.lock" 2>/dev/null || true; i=0; fi
        sleep 0.1
    done
}
reg_unlock() { rmdir "$1.lock" 2>/dev/null || true; }
# Files lookups read: $FILES, the manifest folders of the repo at $PWD, every state folder.
reg_read_files() {
    local f d
    [[ -z "${FILES:-}" ]] || echo "$FILES/workers.tsv"
    d=$(ws_dir "$PWD" 2>/dev/null) || d=""
    for f in ${d:+"$d"/*/workers.tsv} "$REG_STATE"/*/workers.tsv; do [[ -f "$f" ]] && echo "$f"; done
    return 0
}
# reg_put <file> <name> <backend> <tid> <pane> <cwd> <status>: replaces the row of <name>.
reg_put() {
    local f=$1 tmp rc=0
    mkdir -p "$(dirname "$f")" || return 1
    reg_lock "$f"
    tmp=$(mktemp "$f.XXXXXX") && {
        { [[ ! -f "$f" ]] || awk -F'\t' -v n="$2" '$1 != n' "$f"
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "$7" "$(date +%Y-%m-%dT%H:%M:%S)"; } >"$tmp" \
            && mv "$tmp" "$f"
    } || rc=1
    reg_unlock "$f"
    return $rc
}
# reg_find <name>: prints "<file><TAB><row>" of the registry row for the name with the newest start time (empty = none).
reg_find() {
    local f
    while IFS= read -r f; do
        awk -F'\t' -v n="$1" -v f="$f" '$1 == n { print $7 "\t" f "\t" $0 }' "$f"
    done < <(reg_read_files) | sort | tail -n 1 | cut -f2-
}
# reg_mark <name> <status>: sets the status column in every registry file holding the name.
reg_mark() {
    local f tmp
    while IFS= read -r f; do
        grep -q "^$1$TAB" "$f" || continue
        reg_lock "$f"
        tmp=$(mktemp "$f.XXXXXX") && awk -F'\t' -v OFS='\t' -v n="$1" -v s="$2" '$1 == n { $6 = s } 1' "$f" >"$tmp" \
            && mv "$tmp" "$f" || true
        reg_unlock "$f"
    done < <(reg_read_files)
}

# resolve <name>: sets TARGET to what the backend can address (name, else the registered terminal). Returns 1 if gone.
resolve() {
    TARGET=$1
    [[ $(be_state "$1") != gone ]] && return 0
    local hit tid=""
    hit=$(reg_find "$1")
    if [[ -n "$hit" ]]; then IFS=$'\t' read -r _ _ _ tid _ <<<"$hit"; fi
    [[ -n "$tid" ]] || return 1
    if [[ $BE == herdr ]]; then
        TARGET=$(herdr agent list 2>/dev/null | jq -r --arg t "$tid" '.result.agents[] | select(.terminal_id == $t) | .pane_id' | head -1) || TARGET=""
    else
        TARGET=$tid
        [[ $(be_state "$tid") != gone ]] || TARGET=""
    fi
    if [[ -z "$TARGET" ]]; then TARGET=$1; reg_mark "$1" dead; return 1; fi
    echo "Resolved $1 via registry ($TARGET)." >&2
}

# ---- reports -------------------------------------------------------------------------------------------------------
# report_type <file> [marker]: REPORT or QUESTION if the file's last non-empty line starts so (and is newer than marker).
report_type() {
    [[ -s "$1" ]] || return 1
    [[ -z "${2:-}" || "$1" -nt "$2" ]] || return 1
    local last
    last=$(awk 'NF { l = $0 } END { print l }' "$1")
    case $last in REPORT*) echo REPORT; return 0 ;; QUESTION*) echo QUESTION; return 0 ;; esac
    return 1
}
# first_report <marker> <file…>: prints "TYPE file" for the first finished report.
first_report() {
    local m=$1 f t; shift
    for f in "$@"; do if t=$(report_type "$f" "$m"); then echo "$t $f"; return 0; fi; done
    return 1
}
# wait_reports <timeout sec, 0 = none> <marker> <file…>: polls; prints "TYPE file". Returns 4 on timeout, 5 when one
# of the agents in WATCH is blocked, in error or gone (prints "<state> <agent>").
wait_reports() {
    local to=$1 m=$2 t=0 a s; shift 2
    while ! first_report "$m" "$@"; do
        if ((t % 10 == 0)); then
            for a in ${WATCH[@]+"${WATCH[@]}"}; do
                if resolve "$a" 2>/dev/null; then s=$(be_state "$TARGET"); else s=gone; fi
                case $s in blocked | error | gone) echo "$s $a"; return 5 ;; esac
            done
        fi
        ((to == 0 || t < to)) || { echo "timeout"; return 4; }
        sleep 2; t=$((t + 2))
    done
}
# send_failed <output of the failed send>: with --wait a failure can also mean "sent, but the wait ended early".
# Not delivered (or no --wait) -> exit 1; a wait that timed out or stalled is fine; anything else is shown as a warning.
send_failed() {
    if [[ $WAIT == 0 ]] || grep -qE 'agent_blocked|not_found|not found|no terminal|no agent' <<<"$1"; then
        echo "Prompt to $NAME was not sent: ${1:-no error text}" >&2; exit 1
    fi
    grep -qE 'timeout|timed out|agent_prompt_stalled' <<<"$1" \
        || echo "Warning: sending to $NAME reported an error; check with 'ws-agent.sh read $NAME' whether the prompt arrived: $1" >&2
}

# live_names <prefix>: names of the live agents starting with <prefix>, one per line.
live_names() {
    if [[ $BE == herdr ]]; then herdr agent list | jq -r --arg p "$1" '.result.agents[] | select(.name != null and (.name | startswith($p))) | .name'
    else hc ls --json | jq -r --arg p "$1" '.terminals[] | select(.name != null and (.name | startswith($p))) | .name'; fi
}
# limit_check <key> <max> <name> <prefix>: exit 6 when <max> other agents named <prefix>… are alive.
limit_check() {
    local others n
    [[ -n "$2" ]] || return 0
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || { echo "$1 must be a number from 1 (or empty), got '$2'." >&2; exit 1; }
    others=$(live_names "$4" | grep -vx "$3" || true)
    n=$(grep -c . <<<"$others" || true)
    ((n < $2)) || {
        echo "Worker limit reached ($1=$2), alive: $(tr '\n' ' ' <<<"$others"). Give the task to one of them (ws-agent.sh prompt) or end a finished one (ws-agent.sh stop <name>), then start $3." >&2
        exit 6
    }
}
# check_limits <name> <cwd> <workspace>: enforces WS_IMPLEMENT_MAX (names <slug>-impl-…) and WS_WORKERS_MAX (names
# "<slug of --ws>-…") of the main project: the repo this command runs in, else the one of <cwd>.
check_limits() {
    local main slug
    main=$(ws_main "$PWD" 2>/dev/null) || main=""
    [[ -n "$main" ]] || main=$(ws_main "$2" 2>/dev/null) || return 0
    ws_config "$main"
    [[ "$1" != *-impl-* ]] || limit_check WS_IMPLEMENT_MAX "$WS_IMPLEMENT_MAX" "$1" "${1%%-impl-*}-impl-"
    [[ -n "$3" ]] || return 0
    slug=$(ws_slug "$3")
    [[ "$1" != "$slug"-* ]] || limit_check WS_WORKERS_MAX "$WS_WORKERS_MAX" "$1" "$slug-"
}
# stop_agent <name>: ends it for good and marks it dead in the registry. Returns 1 if it could not be ended.
stop_agent() {
    local pane
    resolve "$1" || { echo "$1 is already gone."; return 0; }
    if [[ -n "${HC_TERMINAL_ID:-}" && "$TARGET" == "$HC_TERMINAL_ID" ]]; then
        echo "$1 is the agent this command runs in; not stopped." >&2; return 1
    fi
    if [[ $BE == herdr ]]; then
        pane=$(herdr agent get "$TARGET" 2>/dev/null | jq -r '.result.agent.pane_id // empty') || pane=""
        [[ -n "$pane" ]] || { echo "No pane found for $1." >&2; return 1; }
        [[ "$pane" != "${HERDR_PANE_ID:-}" ]] || { echo "$1 is the agent this command runs in; not stopped." >&2; return 1; }
        herdr pane close "$pane" >/dev/null || return 1
    else
        hc kill "$TARGET" >/dev/null || return 1
        hc rm "$TARGET" >/dev/null 2>&1 || true
    fi
    reg_mark "$1" dead
    echo "$1 stopped"
}

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
        [[ "$NAME" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || { echo "Invalid agent name '$NAME': [a-z][a-z0-9_-]{0,31}." >&2; exit 1; }
        [[ -d "$CWD" ]] || { echo "--cwd DIR required" >&2; exit 1; }
        check_limits "$NAME" "$CWD" "$WSN"
        ARGS=()
        while IFS= read -r a; do ARGS+=("$a"); done < <(ws_agent_args "$KIND" "$MODEL" "$EFFORT" "$EXTRA")
        PANE="" TID=""
        if [[ $BE == herdr ]]; then
            WSID=$(ws_wsid "$CWD"); [[ -n "$WSID" ]] || { echo "No Herdr workspace shows $CWD."; exit 1; }
            PANES=$(herdr pane list --workspace "$WSID" | jq -c '.result.panes')
            LAST=$(jq -r '.[-1].pane_id' <<<"$PANES")
            DIR=right; (($(jq length <<<"$PANES") % 2 == 1)) || DIR=down
            PANE=$(herdr pane split "$LAST" --direction "$DIR" --cwd "$CWD" --no-focus | jq -r '.result.pane.pane_id')
            # agent_not_ready (e.g. the trust dialog) keeps the name; be_wait_idle below deals with it. Other errors stop here.
            OUT=$(herdr agent start "$NAME" --kind "$KIND" --pane "$PANE" ${ARGS[@]+-- "${ARGS[@]}"} 2>&1) \
                || [[ "$OUT" == *agent_not_ready* ]] || { echo "$OUT" >&2; exit 1; }
            TID=$(herdr agent list | jq -r --arg p "$PANE" '.result.agents[] | select(.pane_id == $p) | .terminal_id' | head -1) || TID=""
        else
            hc run --bg --no-parent --keep --name "$NAME" --cwd "$CWD" ${WSN:+--label "ws=$WSN"} --label "role=$NAME" \
                "$KIND" ${ARGS[@]+"${ARGS[@]}"} >/dev/null
            TID=$(hc get "$NAME" --json 2>/dev/null | jq -r '.address // empty') || TID=""
        fi
        if [[ -z "$TID" ]]; then
            echo "Warning: no terminal id for $NAME, so it is not in the worker registry (a lost name cannot be recovered)." >&2
        else
            reg_put "$(reg_write_file "$WSN" "$CWD")" "$NAME" "$BE" "$TID" "$PANE" "$CWD" live \
                || echo "Warning: could not write the worker registry." >&2
        fi
        [[ $WAIT == 0 ]] || be_wait_idle "$NAME" 600
        echo "$NAME started ($BE)" ;;
    prompt)
        NAME=${1:?name}; TEXT=${2:?text}; shift 2
        WAIT=0 TIMEOUT="" REPORT="" UNTIL=0
        while (($#)); do
            case $1 in
                --wait) WAIT=1; shift ;; --timeout) TIMEOUT=${2:?--timeout needs seconds}; is_num "$TIMEOUT"; shift 2 ;;
                --report) REPORT=${2:?--report needs a file}; WAIT=1; shift 2 ;; --until-report) UNTIL=1; shift ;;
                *) echo "Unknown option $1"; exit 1 ;;
            esac
        done
        [[ $UNTIL == 0 || -n "$REPORT" ]] || { echo "--until-report needs --report FILE"; exit 1; }
        [[ "$TEXT" != -* ]] || TEXT=" $TEXT"   # a text starting with - must not be read as an option
        resolve "$NAME" || { echo "Agent $NAME is gone." >&2; exit 1; }
        T=$TARGET
        # --until-report waits for the file itself, so the turn wait must not be cut off by the timeout.
        if [[ $UNTIL == 1 ]]; then SAVED=${TIMEOUT:-$REPORT_TIMEOUT}; TIMEOUT=0; else TIMEOUT=${TIMEOUT:-0}; fi
        build_opts
        be_wait_idle "$T" 600
        MARK=""   # a report must be newer than the prompt: marker made right before sending, not before the idle wait
        if [[ -n "$REPORT" ]]; then MARK=$(mktemp); trap 'rm -f "$MARK"' EXIT; fi
        if [[ $BE == herdr ]]; then OUT=$(herdr agent prompt "$T" "$TEXT" ${OPTS[@]+"${OPTS[@]}"} 2>&1) || send_failed "$OUT"
        else OUT=$(hc send "$T" "$TEXT" --json ${OPTS[@]+"${OPTS[@]}"} 2>&1) || send_failed "$OUT"; fi
        [[ $WAIT == 0 ]] || STATE=$(be_state "$T")
        if [[ -z "$REPORT" ]]; then [[ $WAIT == 0 ]] || echo "$STATE"; exit 0; fi
        if HIT=$(first_report "$MARK" "$REPORT"); then echo "$STATE"; echo "$HIT"; exit 0; fi
        if [[ $UNTIL == 0 ]]; then
            echo "still-working"; echo "Turn ended ($STATE) but $REPORT has no REPORT/QUESTION end line yet." >&2; exit 3
        fi
        TIMEOUT=$SAVED; t=0
        while ! HIT=$(first_report "$MARK" "$REPORT"); do
            STATE=$(be_state "$T")
            case $STATE in blocked | error | gone) echo "$STATE"; exit 5 ;; esac
            if ((TIMEOUT > 0 && t >= TIMEOUT)); then echo "timeout"; exit 4; fi
            sleep 2; t=$((t + 2))
        done
        echo "$STATE"; echo "$HIT" ;;
    wait-report)
        FILE=${1:?file}; shift
        FILES_=("$FILE") TIMEOUT=$REPORT_TIMEOUT MARK="" WATCH=()
        while (($#)); do
            case $1 in
                --timeout) TIMEOUT=${2:?--timeout needs seconds}; is_num "$TIMEOUT"; shift 2 ;;
                --agent) WATCH+=("${2:?--agent needs a name}"); shift 2 ;;
                --fresh) MARK=$(mktemp); trap 'rm -f "$MARK"' EXIT; shift ;;   # ignore reports that exist already
                --any) shift; while (($#)) && [[ $1 != --* ]]; do FILES_+=("$1"); shift; done ;;
                *) echo "Unknown option $1"; exit 1 ;;
            esac
        done
        [[ ${#WATCH[@]} == 0 || "$BE" != none ]] || { echo "--agent needs a backend (Herdr or herdr-core)." >&2; exit 1; }
        wait_reports "$TIMEOUT" "$MARK" "${FILES_[@]}" || exit $? ;;
    state) resolve "${1:?name}" || { echo gone; exit 0; }; be_state "$TARGET" ;;
    wait)
        NAME=${1:?name}; shift
        WAIT=0 TIMEOUT=0
        while (($#)); do case $1 in --timeout) TIMEOUT=${2:?--timeout needs seconds}; is_num "$TIMEOUT"; shift 2 ;; *) echo "Unknown option $1"; exit 1 ;; esac; done
        resolve "$NAME" || { echo gone; exit 0; }
        build_opts
        if [[ $BE == herdr ]]; then herdr agent wait "$TARGET" ${OPTS[@]+"${OPTS[@]}"} >/dev/null || true
        else hc wait "$TARGET" ${OPTS[@]+"${OPTS[@]}"} >/dev/null || true; fi
        be_state "$TARGET" ;;
    read)
        NAME=${1:?name}; LINES_=${2:-80}
        resolve "$NAME" || { echo "Agent $NAME is gone." >&2; exit 1; }
        if [[ $BE == herdr ]]; then herdr agent read "$TARGET" --source recent-unwrapped --lines "$LINES_"
        else hc read "$TARGET" | tail -n "$LINES_"; fi ;;
    list)
        PREFIX=${1:-}
        names=$(live_names "$PREFIX")
        while IFS= read -r n; do [[ -z "$n" ]] || echo "$n $(be_state "$n")"; done <<<"$names"
        # registered workers that no longer answer to their name (renamed or lost): resolve through the registry
        while IFS= read -r f; do
            awk -F'\t' -v p="$PREFIX" 'index($1, p) == 1 { print $1 }' "$f"
        done < <(reg_read_files) | sort -u | while IFS= read -r n; do
            grep -qx "$n" <<<"$names" || { if resolve "$n" 2>/dev/null; then echo "$n $(be_state "$TARGET") (via registry)"; else echo "$n gone (registry: dead)"; fi; }
        done ;;
    stop) stop_agent "${1:?name}" ;;
    stop-all)
        PREFIX=${1:?prefix, e.g. <slug>-}
        RC=0
        while IFS= read -r n; do [[ -z "$n" ]] || stop_agent "$n" || RC=1; done < <(live_names "$PREFIX")
        exit $RC ;;
    focus)
        resolve "${1:?name}" || { echo "Agent $1 is gone." >&2; exit 1; }
        if [[ $BE == herdr ]]; then herdr agent focus "$TARGET" >/dev/null; else echo "Attach with: hc attach $TARGET"; fi ;;
    notify)
        if [[ $BE == herdr ]]; then herdr notification show "${1:?title}" ${2:+--body "$2"} --sound request >/dev/null
        else echo "NOTIFY: $1${2:+ — $2}" >&2; ! command -v notify-send >/dev/null || notify-send "$1" "${2:-}" || true; fi ;;
    *) echo "Unknown command $CMD"; exit 1 ;;
esac
