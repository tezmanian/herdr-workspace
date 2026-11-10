#!/usr/bin/env bash
# Prepares the worktree in the current directory (ws-start.sh runs it in a "setup" tab). Copies untracked files from the
# main checkout, waits for the parent workspace (sub repos build on its exports), runs the project setup and writes
# the state file last, so its existence means "ready". Safe to rerun.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "${WS_WORKTREE_PATH:-$PWD}"
MAIN=$(ws_main .)
[[ "$MAIN" != "$PWD" ]] || { echo "Run inside a worktree, not the main checkout."; exit 1; }
ws_config "$MAIN"
WT=$PWD
STATE=$(ws_state .)
rm -f "$STATE"

clone_dir() {   # copy-on-write when the filesystem allows it
    cp -a --reflink=auto "$1" "$2" 2>/dev/null || cp -Rc "$1" "$2" 2>/dev/null || cp -R "$1" "$2"
}

EXCLUDES=(--exclude=.git)
for e in $WS_COPY_EXCLUDE $WS_CLONE; do EXCLUDES+=(--exclude="$e"); done
COPY=()
for p in $WS_COPY; do [[ ! -e "$MAIN/$p" ]] || COPY+=("$p"); done
((${#COPY[@]} == 0)) || (cd "$MAIN" && rsync -aR --ignore-existing "${EXCLUDES[@]}" "${COPY[@]}" "$WT/")
if [[ -n "$WS_COPY_PATTERNS" ]]; then
    INCLUDES=(--include='*/')
    for p in $WS_COPY_PATTERNS; do INCLUDES+=(--include="$p"); done
    rsync -a --ignore-existing --prune-empty-dirs "${EXCLUDES[@]}" "${INCLUDES[@]}" --exclude='*' "$MAIN/" .
fi
for c in $WS_CLONE; do
    [[ -e "$c" || ! -e "$MAIN/$c" ]] || clone_dir "$MAIN/$c" "$c"
done

PARENT=${WS_PARENT:-$(ws_parent_of "$MAIN" "$PWD")}
if [[ -z "$PARENT" ]]; then   # sub repo: its manifest lives in the main project's repo, not in this one
    for d in "$(dirname "$MAIN")"/*/.git; do
        [[ -d "$d" ]] || continue
        PARENT=$(ws_parent_of "$(dirname "$d")" "$PWD")
        [[ -z "$PARENT" ]] || break
    done
fi
if [[ -n "$PARENT" ]]; then
    PARENT_STATE=$(ws_state "$PARENT")
    for _ in $(seq 180); do
        [[ -f "$PARENT_STATE" ]] && break
        echo "Waiting for the parent workspace setup ($PARENT)…"
        sleep 10
    done
    [[ -f "$PARENT_STATE" ]] || { echo "Parent setup did not finish within 30 minutes."; exit 1; }
    set -a
    source "$PARENT_STATE"
    set +a
fi

export WS_MAIN=$MAIN WS_EXPORT="$STATE.tmp"
: > "$WS_EXPORT"
[[ -z "$WS_SETUP" ]] || eval "$WS_SETUP"
[[ -z "$WS_POST_SETUP" ]] || eval "$WS_POST_SETUP"
mv "$WS_EXPORT" "$STATE"
echo "Workspace ready: $PWD"
cat "$STATE"
