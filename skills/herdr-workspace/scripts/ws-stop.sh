#!/usr/bin/env bash
# Removes workspace <name>: sub worktrees first, then the main one; with --sub only those sub workspaces. Branches stay.
# Refuses on uncommitted changes. Untracked files listed in WS_KEEP / WS_KEEP_PATTERNS that differ from the main
# checkout are handled per WS_IGNORED_ON_REMOVE or the flag: ask (list them, remove nothing), copy (into the main
# checkout), delete. Runs each repo's WS_TEARDOWN first (Herdr has no archive hook: remove workspaces with this script).
# Worktrees that vanished on disk are dropped from the manifest.
# Usage (inside any checkout of the main project): ws-stop.sh <name> [--ask|--copy|--delete] [--sub REPO]... [--on MACHINE --remote-dir DIR]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ws_remote "$@"
NAME=${1:?usage: ws-stop.sh <name> [--ask|--copy|--delete] [--sub REPO]...}
shift
MODE="" ONLY=()
MAIN=$(ws_main .)
WS_MAIN_PROJECT=$MAIN
while (($#)); do
    case $1 in
        --ask|--copy|--delete) MODE=${1#--}; shift ;;
        --sub) ONLY+=("$(ws_repo_path "$2")"); shift 2 ;;
        *) echo "Unknown option $1"; exit 1 ;;
    esac
done
ws_config "$MAIN"
MODE=${MODE:-$WS_IGNORED_ON_REMOVE}
MANIFEST=$(ws_dir "$MAIN")/$NAME.env
ROOT=$(ws_get "$MAIN" "$NAME" main)
[[ -n "$ROOT" ]] || { echo "No workspace $NAME."; exit 1; }

drop_sub() { grep -vF "sub=$1|" "$MANIFEST" > "$MANIFEST.tmp" || true; mv "$MANIFEST.tmp" "$MANIFEST"; }
finish_root() { rm -f "$MANIFEST"; rm -rf "$(dirname "$MANIFEST")/$NAME"; }

CANDIDATES=()
for wt in $(ws_children "$MAIN" "$NAME"); do CANDIDATES+=("$wt"); done
((${#ONLY[@]})) || CANDIDATES+=("$ROOT")
TREES=()
for wt in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    if [[ -d "$wt" ]]; then
        m=$(ws_main "$wt")
        ((${#ONLY[@]} == 0)) || [[ " ${ONLY[*]} " == *" $m "* ]] || continue
        TREES+=("$wt")
    else
        echo "Gone from disk: $wt (dropped from the manifest)."
        git -C "$MAIN" worktree prune
        if [[ "$wt" == "$ROOT" ]]; then finish_root; else drop_sub "$wt"; fi
    fi
done
((${#TREES[@]})) || { echo "Nothing left to remove."; exit 0; }

# rsync arguments selecting the files to keep, relative to the worktree (one per line, no globbing of the ***).
KEEP_ARGS=()
keep_args() {
    local p
    KEEP_ARGS=()
    read -ra W <<<"$WS_KEEP_PATTERNS" || true
    for p in ${W[@]+"${W[@]}"}; do KEEP_ARGS+=("--include=$p"); done
    read -ra W <<<"$WS_KEEP" || true
    for p in ${W[@]+"${W[@]}"}; do KEEP_ARGS+=("--include=/$p" "--include=/$p/***"); done
}

DIRTY=0
for wt in "${TREES[@]}"; do
    changes=$(git -C "$wt" status --porcelain)
    [[ -z "$changes" ]] || { echo "Uncommitted in $wt:"; echo "$changes"; DIRTY=1; }
done
((DIRTY == 0)) || { echo "Commit or discard first."; exit 1; }

PENDING=0
for wt in "${TREES[@]}"; do
    m=$(ws_main "$wt")
    ws_config "$m"
    [[ -n "$WS_KEEP$WS_KEEP_PATTERNS" ]] || continue
    keep_args
    filter=(--exclude=.git --include='*/' ${KEEP_ARGS[@]+"${KEEP_ARGS[@]}"} --exclude='*')
    changed=$(rsync -anc --prune-empty-dirs "${filter[@]}" --out-format='%n' "$wt/" "$m/" | grep -v '/$' || true)
    [[ -n "$changed" ]] || continue
    case $MODE in
        ask) echo "Untracked changes in $wt (not in $m):"; echo "$changed"; PENDING=1 ;;
        copy) rsync -a --prune-empty-dirs "${filter[@]}" "$wt/" "$m/"; echo "Copied into $m:"; echo "$changed" ;;
        delete) echo "Discarding untracked changes in $wt." ;;
    esac
done
((PENDING == 0)) || { echo "Rerun with --copy or --delete."; exit 2; }

for wt in "${TREES[@]}"; do
    ws_config "$(ws_main "$wt")"
    [[ -z "$WS_TEARDOWN" ]] || (cd "$wt" && eval "$WS_TEARDOWN")
    be_kill_dir "$wt"
    id=$(ws_wsid "$wt")
    if [[ -n "$id" ]]; then
        herdr worktree remove --workspace "$id" --force >/dev/null
    else
        git -C "$(ws_main "$wt")" worktree remove --force "$wt"
    fi
    if [[ "$wt" == "$ROOT" ]]; then finish_root; else drop_sub "$wt"; fi
    echo "Removed $wt"
done
