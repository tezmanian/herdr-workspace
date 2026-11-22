#!/usr/bin/env bash
# Removes workspace <name>: sub worktrees first, then the main one; with --sub only those sub workspaces. Branches stay.
# Refuses on uncommitted changes. Untracked files listed in WS_KEEP / WS_KEEP_PATTERNS that differ from the main
# checkout are handled per WS_IGNORED_ON_REMOVE or the flag: ask (list them, remove nothing), copy (into the main
# checkout), delete. Runs each repo's WS_TEARDOWN first (Herdr has no archive hook: remove workspaces with this script).
# Worktrees that vanished on disk are dropped from the manifest. Nothing is removed or forgotten before the checks
# pass. A failing WS_TEARDOWN is reported and the removal goes on. Exit: 0 done, 1 error or uncommitted changes,
# 2 untracked files need --copy or --delete.
# Usage (inside any checkout of the main project): ws-stop.sh <name> [--ask|--copy|--delete] [--sub REPO]... [--on MACHINE --remote-dir DIR]
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ws_help "$@"
ws_remote "$@"
NAME=${1:?usage: ws-stop.sh <name> [--ask|--copy|--delete] [--sub REPO]...   (--help for more)}
shift
case $NAME in */* | . | .. | -*) echo "Invalid workspace name '$NAME' (see --help)." >&2; exit 1 ;; esac
MODE="" ONLY=() ONLY_ARGS=()
MAIN=$(ws_main .)
WS_MAIN_PROJECT=$MAIN
while (($#)); do
    case $1 in
        --ask|--copy|--delete) MODE=${1#--}; shift ;;
        --sub) r=$(ws_repo_path "${2:?--sub needs a repo}"); ONLY+=("$r"); ONLY_ARGS+=("$2"); shift 2 ;;
        *) echo "Unknown option $1 (see --help)" >&2; exit 1 ;;
    esac
done
ws_config "$MAIN"
MODE=${MODE:-$WS_IGNORED_ON_REMOVE}
MANIFEST=$(ws_dir "$MAIN")/$NAME.env
ROOT=$(ws_get "$MAIN" "$NAME" main)
[[ -n "$ROOT" ]] || { echo "No workspace $NAME." >&2; exit 1; }

drop_sub() {
    [[ -f "$MANIFEST" ]] || return 0
    grep -vF "sub=$1|" "$MANIFEST" > "$MANIFEST.tmp" || true
    mv "$MANIFEST.tmp" "$MANIFEST"
}
# Manifest, workspace files (reports, decisions, registry) and the registry in the state folder.
finish_root() {
    rm -f "$MANIFEST"
    rm -rf "$(dirname "$MANIFEST")/$NAME" "${HERDR_WORKSPACE_STATE:-$HOME/.local/state/herdr-workspace}/$NAME"
}
is_only() { local o; for o in ${ONLY[@]+"${ONLY[@]}"}; do [[ "$o" != "$1" ]] || return 0; done; return 1; }

CANDIDATES=()
while IFS= read -r wt; do [[ -z "$wt" ]] || CANDIDATES+=("$wt"); done < <(ws_children "$MAIN" "$NAME")
((${#ONLY[@]})) || CANDIDATES+=("$ROOT")
# TREES: worktrees to remove. GONE: manifest entries whose folder vanished; they are dropped only after the checks below.
TREES=() GONE=() SEEN=()
for wt in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    if [[ -d "$wt" ]]; then
        m=$(ws_main "$wt")
        SEEN+=("$m")
        ((${#ONLY[@]} == 0)) || is_only "$m" || continue
        TREES+=("$wt")
    else
        GONE+=("$wt")
    fi
done
# A --sub that names no sub workspace of this one is a mistake, not "nothing to do".
i=0
for o in ${ONLY[@]+"${ONLY[@]}"}; do
    found=0
    for m in ${SEEN[@]+"${SEEN[@]}"}; do [[ "$m" != "$o" ]] || found=1; done
    ((found)) || ((${#GONE[@]})) || { echo "Workspace $NAME has no sub workspace for ${ONLY_ARGS[i]} ($o); see ws-status.sh $NAME." >&2; exit 1; }
    i=$((i + 1))
done

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
for wt in ${TREES[@]+"${TREES[@]}"}; do
    changes=$(git -C "$wt" status --porcelain)
    [[ -z "$changes" ]] || { echo "Uncommitted in $wt:"; echo "$changes"; DIRTY=1; }
done
((DIRTY == 0)) || { echo "Commit or discard first."; exit 1; }

PENDING=0
for wt in ${TREES[@]+"${TREES[@]}"}; do
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

# The checks passed: now forget what vanished on disk (the main worktree last, with the workspace files).
ROOT_GONE=0
for wt in ${GONE[@]+"${GONE[@]}"}; do
    echo "Gone from disk: $wt (dropped from the manifest)."
    if [[ "$wt" == "$ROOT" ]]; then ROOT_GONE=1; else drop_sub "$wt"; fi
done
((${#GONE[@]} == 0)) || git -C "$MAIN" worktree prune || true
((${#TREES[@]})) || ((ROOT_GONE)) || { echo "Nothing left to remove."; exit 0; }

for wt in ${TREES[@]+"${TREES[@]}"}; do
    ws_config "$(ws_main "$wt")"
    if [[ -n "$WS_TEARDOWN" ]]; then
        (cd "$wt" && eval "$WS_TEARDOWN") \
            || echo "Warning: WS_TEARDOWN failed in $wt (exit $?); removing the worktree anyway. Clean up by hand what it should have stopped (containers, VMs)." >&2
    fi
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
((ROOT_GONE == 0)) || finish_root
