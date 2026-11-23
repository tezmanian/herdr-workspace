#!/usr/bin/env bash
# Tests for the herdr-workspace scripts. Everything happens in throwaway repos under a temp folder.
# Part 1 needs only git, jq, rsync. Part 2 (a whole workspace cycle and worker limits) needs a running herdr-core
# (`hc server status`) and is skipped without it; its terminals are plain shells, no agent is started.
# Usage: tests/run.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
W=$ROOT/skills/herdr-workspace/scripts
T=$(mktemp -d)
PASS=0 FAIL=0
PFX=wst$$                                    # name prefix of everything this run starts

cleanup() {
    if command -v hc >/dev/null; then
        for a in $(hc ls --all --json 2>/dev/null | jq -r --arg p "$T" '.terminals[]? | select((.cwd // "") | startswith($p)) | .address'); do
            hc kill "$a" >/dev/null 2>&1; hc rm "$a" >/dev/null 2>&1
        done
    fi
    rm -rf "$T"
}
trap cleanup EXIT

# t <description> <expected exit code> <text the output must contain, or ""> <command…>
t() {
    local desc=$1 want=$2 text=$3 out rc; shift 3
    out=$("$@" 2>&1); rc=$?
    if [[ $rc == "$want" ]] && { [[ -z "$text" ]] || grep -qF -- "$text" <<<"$out"; }; then PASS=$((PASS + 1)); echo "ok    $desc"
    else FAIL=$((FAIL + 1)); echo "FAIL  $desc (exit $rc, wanted $want${text:+, text '$text'})"; sed 's/^/        /' <<<"$out"; fi
}
repo() { git init -q -b main "$1" && git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; }

export HERDR_WORKSPACE_HOME=$T/cfg HERDR_WORKSPACE_STATE=$T/state HERDR_CONFIG_PATH=$T/config.toml
printf '[worktrees]\ndirectory = "%s/wt"\n' "$T" > "$T/config.toml"
mkdir -p "$T/cfg/projects/api" "$T/cfg/projects/web"
repo "$T/api"; repo "$T/web"
cd "$T/api" || exit 1

echo "== syntax"
for f in "$W"/*.sh "$ROOT"/install.sh "$ROOT"/examples/configs/*/*.sh "$ROOT"/skills/herdr-workspace-config/template/setup.sh; do
    t "bash -n ${f#"$ROOT"/}" 0 "" bash -n "$f"
done
if command -v shellcheck >/dev/null; then
    t "shellcheck (errors only)" 0 "" shellcheck -S error -x "$W"/*.sh
else
    echo "skip  shellcheck not installed"
fi

echo "== arguments (no backend needed)"
for s in ws-start ws-stop ws-status ws-doctor ws-agent ws-setup; do t "$s.sh --help" 0 "$s.sh" "$W/$s.sh" --help; done
t "branch must not look like an option" 1 "not an option" "$W/ws-start.sh" --foo
t "invalid workspace name" 1 "Invalid workspace name" env WS_BACKEND=core "$W/ws-start.sh" "a b" --no-orchestrator
t "ws-stop rejects .." 1 "Invalid workspace name" "$W/ws-stop.sh" ..
t "ws-stop unknown workspace" 1 "No workspace" "$W/ws-stop.sh" nope
t "doctor fails on a missing base branch" 1 "base branch master not found" "$W/ws-doctor.sh"
echo 'WS_BASE_BRANCH=main' > "$T/cfg/projects/api/workspace.env"
t "doctor accepts the configured base branch" 0 "base branch main exists" env WS_BACKEND=core "$W/ws-doctor.sh"

echo "== report waits"
printf 'text\nREPORT x\n\n' > "$T/done.md"; printf 'text\n' > "$T/open.md"; printf 'q\nQUESTION x\n' > "$T/q.md"
t "finished report" 0 "REPORT $T/done.md" "$W/ws-agent.sh" wait-report "$T/done.md"
t "question report via --any" 0 "QUESTION $T/q.md" "$W/ws-agent.sh" wait-report "$T/open.md" --any "$T/q.md"
t "unfinished report times out with 4" 4 "timeout" "$W/ws-agent.sh" wait-report "$T/open.md" --timeout 2
t "--fresh ignores an old report" 4 "timeout" "$W/ws-agent.sh" wait-report "$T/done.md" --fresh --timeout 2
t "timeout must be a number" 1 "whole seconds" "$W/ws-agent.sh" wait-report "$T/open.md" --timeout soon

echo "== parent exports are data"
git -C "$T/api" worktree add -q -b p1 "$T/wt/api/p1" main; git -C "$T/web" worktree add -q -b p1 "$T/wt/web/p1" main
cat > "$T/cfg/projects/api/workspace.env" <<'CFG'
WS_BASE_BRANCH=main
WS_SETUP='printf "%s\n" "API_URL=http://x y" "EVIL=\$(touch $WS_MAIN/../pwned)" "junk; touch $WS_MAIN/../pwned" >> "$WS_EXPORT"'
CFG
printf 'WS_BASE_BRANCH=main\nWS_SETUP=%s\n' "'echo \"GOT=\$API_URL\" >> \"\$WS_EXPORT\"'" > "$T/cfg/projects/web/workspace.env"
t "parent setup" 0 "API_URL=http://x y" env WS_WORKTREE_PATH="$T/wt/api/p1" "$W/ws-setup.sh"
t "sub setup reads the parent's exports literally" 0 "GOT=http://x y" env WS_WORKTREE_PATH="$T/wt/web/p1" WS_PARENT="$T/wt/api/p1" "$W/ws-setup.sh"
t "no export line was executed" 1 "" test -e "$T/pwned"
git -C "$T/api" worktree remove --force "$T/wt/api/p1"; git -C "$T/web" worktree remove --force "$T/wt/web/p1"

echo "== slot example"
slot() { (cd "$1" && XDG_STATE_HOME=$T/xdg bash -c 'set -euo pipefail; '"$(sed -n '/^SLOTS=/,/^\[\[ -n "\$SLOT"/p' "$ROOT/examples/configs/api/setup.sh")"'; echo "$SLOT"'); }
mkdir -p "$T/s1" "$T/s2"
t "first worktree gets slot 10" 0 "10" slot "$T/s1"
t "second worktree gets another slot" 0 "11" slot "$T/s2"
t "a rerun keeps its slot" 0 "10" slot "$T/s1"

if ! command -v hc >/dev/null || ! hc server status >/dev/null 2>&1; then
    echo "skip  herdr-core not running: workspace cycle and worker limits not tested"
else
    export WS_BACKEND=core
    N=$PFX
    echo "== workspace cycle (herdr-core)"
    printf 'WS_BASE_BRANCH=main\nWS_SUBS="web"\nWS_IMPLEMENT_MAX=1\nWS_WORKERS_MAX=2\nWS_SETUP=%s\n' "'echo \"API_URL=http://api\" >> \"\$WS_EXPORT\"'" > "$T/cfg/projects/api/workspace.env"
    printf 'WS_BASE_BRANCH=main\nWS_TEARDOWN=false\nWS_SETUP=%s\n' "'echo \"GOT=\$API_URL\" >> \"\$WS_EXPORT\"'" > "$T/cfg/projects/web/workspace.env"
    t "start with the default sub" 0 "sub:  $T/wt/web/$N" "$W/ws-start.sh" "feat/$N" --name "$N" --no-orchestrator
    t "manifest has the sub" 0 "sub=$T/wt/web/$N|" cat "$T/api/.git/herdr-workspace/$N.env"
    t "rerun with another branch is refused" 1 "exists on branch feat/$N" "$W/ws-start.sh" other --name "$N"
    for _ in $(seq 30); do [[ -f "$T/web/.git/worktrees/$N/workspace.env" ]] && break; sleep 1; done
    t "background setup got the caller's config (sub has the parent's export)" 0 "GOT=http://api" "$W/ws-status.sh" "$N"

    echo "== workers and limits"
    A="$W/ws-agent.sh"
    t "first implementer" 0 "started" "$A" start "$N-impl-api" --cwd "$T/wt/api/$N" --kind sh --ws "$N" --no-wait
    t "registry is in the workspace files folder" 0 "$N-impl-api" cat "$T/api/.git/herdr-workspace/$N/workers.tsv"
    t "second implementer hits WS_IMPLEMENT_MAX" 6 "WS_IMPLEMENT_MAX=1" "$A" start "$N-impl-web" --cwd "$T/wt/web/$N" --kind sh --ws "$N" --no-wait
    t "another role still fits" 0 "started" "$A" start "$N-plan" --cwd "$T/wt/api/$N" --kind sh --ws "$N" --no-wait
    t "third worker hits WS_WORKERS_MAX" 6 "WS_WORKERS_MAX=2" "$A" start "$N-decider" --cwd "$T/wt/api/$N" --kind sh --ws "$N" --no-wait
    t "status lists the agents" 0 "$N-plan" "$W/ws-status.sh" "$N"
    t "wait-report --agent ends when the worker is gone" 5 "gone $N-nobody" "$A" wait-report "$T/open.md" --agent "$N-nobody" --timeout 20
    t "stop frees the slot" 0 "stopped" "$A" stop "$N-impl-api"
    t "now the other implementer starts" 0 "started" "$A" start "$N-impl-web" --cwd "$T/wt/web/$N" --kind sh --ws "$N" --no-wait
    t "invalid agent name" 1 "Invalid agent name" "$A" start "Bad_Name" --cwd "$T/wt/api/$N"
    t "prompt to a missing agent fails" 1 "is gone" "$A" prompt "$N-nobody" hi

    echo "== stop"
    mkdir "$T/other"; repo "$T/other"
    t "--sub outside the workspace is an error" 1 "has no sub workspace" "$W/ws-stop.sh" "$N" --sub "$T/other"
    touch "$T/wt/web/$N/dirty"
    t "uncommitted changes stop the removal" 1 "Commit or discard first" "$W/ws-stop.sh" "$N"
    t "nothing was forgotten" 0 "" test -f "$T/api/.git/herdr-workspace/$N.env" -a -d "$T/wt/api/$N"
    rm "$T/wt/web/$N/dirty"
    t "removal goes on after a failing teardown" 0 "WS_TEARDOWN failed" "$W/ws-stop.sh" "$N"
    t "manifest and files are gone" 1 "" test -e "$T/api/.git/herdr-workspace/$N.env" -o -e "$T/api/.git/herdr-workspace/$N"
    t "workers were ended" 0 "" test -z "$("$A" list "$N-" | grep -v gone)"
fi

echo
echo "$PASS passed, $FAIL failed"
((FAIL == 0))
