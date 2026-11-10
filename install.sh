#!/usr/bin/env bash
# Links the skills of this repo into agent skills folders (symlinks, so `git pull` updates them).
# Usage: ./install.sh [skills dir]...   default: every existing one of ~/.claude/skills, ~/.agents/skills, ~/.codex/skills
#        ./install.sh --remove [skills dir]...
set -euo pipefail
SRC=$(cd "$(dirname "$0")/skills" && pwd)
REMOVE=0
[[ "${1:-}" != --remove ]] || { REMOVE=1; shift; }
TARGETS=("$@")
if ((${#TARGETS[@]} == 0)); then
    for d in "$HOME/.claude/skills" "$HOME/.agents/skills" "$HOME/.codex/skills"; do
        [[ -d "$(dirname "$d")" ]] && TARGETS+=("$d")
    done
fi
((${#TARGETS[@]})) || { echo "No agent skills folder found; pass one, e.g. ./install.sh ~/.claude/skills"; exit 1; }

for t in "${TARGETS[@]}"; do
    mkdir -p "$t"
    for s in "$SRC"/*/; do
        name=$(basename "$s")
        link="$t/$name"
        if ((REMOVE)); then
            [[ ! -L "$link" ]] || { rm "$link"; echo "removed $link"; }
            continue
        fi
        if [[ -e "$link" && ! -L "$link" ]]; then
            echo "skip $link: exists and is not a link (move it away first)"
            continue
        fi
        ln -sfn "${s%/}" "$link"
        echo "linked $link"
    done
done
((REMOVE)) || echo "Next: in your main project, inside Herdr, run the skill herdr-workspace-init (or $SRC/herdr-workspace/scripts/ws-doctor.sh)."
