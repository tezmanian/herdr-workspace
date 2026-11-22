#!/usr/bin/env bash
# Agents (workers) of a workspace, the same on both backends (Herdr 1 panes, herdr-core terminals).
#   ws-agent.sh start <name> --cwd DIR [--kind K] [--model M] [--effort E] [--args "…"] [--ws WORKSPACE] [--no-wait]
#   ws-agent.sh prompt <name> <text> [--wait] [--timeout SEC] [--report FILE [--until-report]]
#                 # waits until the agent is idle first; with --report a turn that ends without a finished
#                 # report file prints "still-working" and exits 3 (--until-report keeps waiting; exit 4 = timeout)
#   ws-agent.sh wait-report <file> [--any FILE…] [--timeout SEC] [--fresh]   # until a file ends with REPORT/QUESTION
#   ws-agent.sh state <name>      # idle | working | blocked | done | error | unknown | gone
#   ws-agent.sh wait <name> [--timeout SEC]   # until it stops working (or blocks); prints the state
#   ws-agent.sh read <name> [lines]
#   ws-agent.sh list [prefix]     # "name state" per line (also registered workers whose name was lost)
#   ws-agent.sh focus <name> | notify <title> [body]
# Names: [a-z][a-z0-9_-]{0,31}; raw pane IDs (w3:p2) work as names too. Workers outlive this command (and, with core,
# an ended ssh link or parent agent).
# Registry: `start` records name -> terminal id in workers.tsv ($FILES, else ~/.local/state/herdr-workspace/<ws>/);
# a name that no longer resolves (e.g. after the orchestrator's /clear) falls back to it. Exit codes of prompt/wait-report:
# 0 ok, 1 error, 3 still working (no report yet), 4 timeout, 5 agent blocked/gone while waiting for a report.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
BE=$WS_BACKEND
CMD=${1:?usage: ws-agent.sh start|prompt|state|wait|wait-report|read|list|focus|notify …}
shift
[[ "$BE" != none || "$CMD" == wait-report ]] || { echo "No backend: run inside Herdr (HERDR_ENV=1) or start herdr-core (hc server status)." >&2; exit 1; }

# ---- registry: workers.tsv, one row per worker: name backend terminal-id pane cwd status(live|dead) started -------
REG_STATE=${HERDR_WORKSPACE_STATE:-$HOME/.local/state/herdr-workspace}
TAB=$'\t'

# File that start writes: $FILES, else the state folder of workspace $1 (default "default").
reg_write_file() {
    if [[ -n "${FILES:-}" ]]; then echo "$FILES/workers.tsv"; else echo "$REG_STATE/${1:-${WS_NAME:-default}}/workers.tsv"; fi
}
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
    local f=$1 tmp
    mkdir -p "$(dirname "$f")"
    tmp=$(mktemp "$f.XXXXXX")
    { [[ ! -f "$f" ]] || awk -F'\t' -v n="$2" '$1 != n' "$f"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" "$7" "$(date +%Y-%m-%dT%H:%M:%S)"; } >"$tmp"
    mv "$tmp" "$f"
}
# reg_find <name>: prints "<file><TAB><row>" of the newest registry row for the name (empty = none).
reg_find() {
    local f
    while IFS= read -r f; do
        awk -F'\t' -v n="$1" -v f="$f" '$1 == n { r = f "\t" $0 } END { if (r) print r }' "$f"
    done < <(reg_read_files) | tail -n 1
}
# reg_mark <name> <status>: sets the status column in every registry file holding the name.
reg_mark() {
    local f tmp
    while IFS= read -r f; do
        grep -q "^$1$TAB" "$f" || continue
        tmp=$(mktemp "$f.XXXXXX")
        awk -F'\t' -v OFS='\t' -v n="$1" -v s="$2" '$1 == n { $6 = s } 1' "$f" >"$tmp" && mv "$tmp" "$f"
    done < <(reg_read_files)
}

# resolve <name>: sets TARGET to what the backend can address (name, else the registered terminal). Returns 1 if gone.
resolve() {
    TARGET=$1
    [[ $(be_state "$1") != gone ]] && return 0
    local hit tid="" pane=""
    hit=$(reg_find "$1")
    if [[ -n "$hit" ]]; then IFS=$'\t' read -r _ _ _ tid pane _ <<<"$hit"; fi
    if [[ -z "$tid" ]]; then [[ "$1" == w*:p* ]] && TARGET=$1; return 1; fi
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
# wait_reports <timeout sec, 0 = none> <marker> <file…>: polls; prints "TYPE file"; 4 on timeout.
wait_reports() {
    local to=$1 m=$2 t=0; shift 2
    while ! first_report "$m" "$@"; do
        ((to == 0 || t < to)) || return 4
        sleep 2; t=$((t + 2))
    done
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
        [[ -d "$CWD" ]] || { echo "--cwd DIR required"; exit 1; }
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
        [[ -z "$TID" ]] || reg_put "$(reg_write_file "$WSN")" "$NAME" "$BE" "$TID" "$PANE" "$CWD" live \
            || echo "Warning: could not write the worker registry." >&2
        [[ $WAIT == 0 ]] || be_wait_idle "$NAME" 600
        echo "$NAME started ($BE)" ;;
    prompt)
        NAME=${1:?name}; TEXT=${2:?text}; shift 2
        WAIT=0 TIMEOUT=0 REPORT="" UNTIL=0
        while (($#)); do
            case $1 in
                --wait) WAIT=1; shift ;; --timeout) TIMEOUT=$2; shift 2 ;;
                --report) REPORT=${2:?--report needs a file}; WAIT=1; shift 2 ;; --until-report) UNTIL=1; shift ;;
                *) echo "Unknown option $1"; exit 1 ;;
            esac
        done
        [[ $UNTIL == 0 || -n "$REPORT" ]] || { echo "--until-report needs --report FILE"; exit 1; }
        [[ "$TEXT" != -* ]] || TEXT=" $TEXT"   # a text starting with - must not be read as an option
        resolve "$NAME" || { echo "Agent $NAME is gone." >&2; exit 1; }
        T=$TARGET
        MARK=""
        if [[ -n "$REPORT" ]]; then MARK=$(mktemp); trap 'rm -f "$MARK"' EXIT; fi   # a report must be newer than the prompt
        # --until-report waits for the file itself, so the turn wait must not be cut off by the timeout.
        if [[ $UNTIL == 1 ]]; then SAVED=$TIMEOUT; TIMEOUT=0; fi
        build_opts
        be_wait_idle "$T" 600
        if [[ $BE == herdr ]]; then herdr agent prompt "$T" "$TEXT" ${OPTS[@]+"${OPTS[@]}"} >/dev/null || [[ $WAIT == 1 ]]
        else hc send "$T" "$TEXT" ${OPTS[@]+"${OPTS[@]}"} >/dev/null || [[ $WAIT == 1 ]]; fi
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
        FILES_=("$FILE") TIMEOUT=0 MARK=""
        while (($#)); do
            case $1 in
                --timeout) TIMEOUT=$2; shift 2 ;;
                --fresh) MARK=$(mktemp); trap 'rm -f "$MARK"' EXIT; shift ;;   # ignore reports that exist already
                --any) shift; while (($#)) && [[ $1 != --* ]]; do FILES_+=("$1"); shift; done ;;
                *) echo "Unknown option $1"; exit 1 ;;
            esac
        done
        wait_reports "$TIMEOUT" "$MARK" "${FILES_[@]}" || { echo "timeout"; exit 4; } ;;
    state) resolve "${1:?name}" || { echo gone; exit 0; }; be_state "$TARGET" ;;
    wait)
        NAME=${1:?name}; shift
        WAIT=0 TIMEOUT=0
        while (($#)); do case $1 in --timeout) TIMEOUT=$2; shift 2 ;; *) echo "Unknown option $1"; exit 1 ;; esac; done
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
        if [[ $BE == herdr ]]; then names=$(herdr agent list | jq -r --arg p "$PREFIX" '.result.agents[] | select(.name != null and (.name | startswith($p))) | .name')
        else names=$(hc ls --json | jq -r --arg p "$PREFIX" '.terminals[] | select(.name != null and (.name | startswith($p))) | .name'); fi
        for n in $names; do echo "$n $(be_state "$n")"; done
        # registered workers that no longer answer to their name (renamed or lost): resolve through the registry
        while IFS= read -r f; do
            awk -F'\t' -v p="$PREFIX" 'index($1, p) == 1 { print $1 }' "$f"
        done < <(reg_read_files) | sort -u | while IFS= read -r n; do
            grep -qx "$n" <<<"$names" || { if resolve "$n" 2>/dev/null; then echo "$n $(be_state "$TARGET") (via registry)"; else echo "$n gone (registry: dead)"; fi; }
        done ;;
    focus)
        resolve "${1:?name}" || { echo "Agent $1 is gone." >&2; exit 1; }
        if [[ $BE == herdr ]]; then herdr agent focus "$TARGET" >/dev/null; else echo "Attach with: hc attach $TARGET"; fi ;;
    notify)
        if [[ $BE == herdr ]]; then herdr notification show "${1:?title}" ${2:+--body "$2"} --sound request >/dev/null
        else echo "NOTIFY: $1${2:+ — $2}" >&2; ! command -v notify-send >/dev/null || notify-send "$1" "${2:-}" || true; fi ;;
    *) echo "Unknown command $CMD"; exit 1 ;;
esac
