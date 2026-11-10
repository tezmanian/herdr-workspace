#!/usr/bin/env bash
# Prepares the worktree in the current directory (ws-start.sh runs it in the background). Copies untracked files from
# the main checkout, waits for the parent workspace (sub repos build on its exports), runs the project setup and writes
# the state file last, so its existence means "ready"; a failure leaves workspace.env.failed. Safe to rerun.
# WS_PARENT=<parent worktree> (set by ws-start.sh, remembered in the git dir for reruns).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
cd "${WS_WORKTREE_PATH:-$PWD}"
MAIN=$(ws_main .)
[[ "$MAIN" != "$PWD" ]] || { echo "Run inside a worktree, not the main checkout."; exit 1; }
ws_config "$MAIN"
WT=$PWD
STATE=$(ws_state .)
PARENT_FILE=$(dirname "$STATE")/ws-parent
rm -f "$STATE" "$STATE.failed"
trap '[[ $? -eq 0 ]] || touch "$STATE.failed"' EXIT

# Copy-on-write when the filesystem allows it; a half-done attempt is removed before the next one.
clone_dir() {
    cp -a --reflink=auto "$1" "$2" 2>/dev/null && return
    rm -rf "$2"; cp -Rc "$1" "$2" 2>/dev/null && return
    rm -rf "$2"; cp -R "$1" "$2"
}
# Config lists are split with read, not left unquoted: no file globbing of patterns like ai-docs/***.
words() { read -ra WORDS <<<"$1" || true; }

words "$WS_COPY_EXCLUDE $WS_CLONE"
EXCLUDES=(--exclude=.git)
for e in ${WORDS[@]+"${WORDS[@]}"}; do EXCLUDES+=(--exclude="$e"); done
words "$WS_COPY"
COPY=()
for p in ${WORDS[@]+"${WORDS[@]}"}; do [[ ! -e "$MAIN/$p" ]] || COPY+=("$p"); done
((${#COPY[@]} == 0)) || (cd "$MAIN" && rsync -aR --ignore-existing "${EXCLUDES[@]}" "${COPY[@]}" "$WT/")
words "$WS_COPY_PATTERNS"
if ((${#WORDS[@]})); then
    INCLUDES=(--include='*/')
    for p in "${WORDS[@]}"; do INCLUDES+=(--include="$p"); done
    rsync -a --ignore-existing --prune-empty-dirs "${EXCLUDES[@]}" "${INCLUDES[@]}" --exclude='*' "$MAIN/" .
fi
words "$WS_CLONE"
for c in ${WORDS[@]+"${WORDS[@]}"}; do
    [[ -e "$c" || ! -e "$MAIN/$c" ]] || clone_dir "$MAIN/$c" "$c"
done

[[ -z "${WS_PARENT:-}" ]] || echo "$WS_PARENT" > "$PARENT_FILE"
PARENT=$([[ ! -f "$PARENT_FILE" ]] || cat "$PARENT_FILE")
if [[ -n "$PARENT" ]]; then
    PARENT_STATE=$(ws_state "$PARENT")
    for _ in $(seq 180); do
        [[ -f "$PARENT_STATE" ]] && break
        [[ ! -f "$PARENT_STATE.failed" ]] || { echo "Parent setup failed ($PARENT); fix it and rerun ws-setup.sh there first."; exit 1; }
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
mv "$WS_EXPORT" "$STATE"
echo "Workspace ready: $PWD"
cat "$STATE"
