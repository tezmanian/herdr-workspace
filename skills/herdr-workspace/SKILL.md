---
name: herdr-workspace
description: "Starts, manages and removes Herdr workspaces: a main worktree on a branch, ticket or free-text task in the repo where it runs (the main project), sub worktrees in other repos (admin UI, frontend, app) wired to it, and an orchestrator agent. Use when the user says \"workspace for PROJ-123\", \"start a workspace\", \"workspace with orchestrator\", \"add frontend\", \"remove sub workspace\", \"workspace status\", \"tear down workspace\", \"/herdr-workspace\"; also for an orchestrator adding or removing sub workspaces. Requires HERDR_ENV=1. Orchestrator playbook: herdr-orchestrator. Repo config: herdr-workspace-config."
---

# Herdr workspace

Generic: the repo the agent runs in is the **main project**; everything project-specific comes from the repo's
config (skill `herdr-workspace-config`). Scripts: `scripts/` next to this file (`$WS` below), run from any checkout
of the main project, inside Herdr (`test "${HERDR_ENV:-}" = 1`, else say so and stop). General Herdr control: skill `herdr`.

A workspace = one Herdr workspace per worktree (main + one per sub repo, same name and branch). Herdr links them
only loosely, so the scripts keep a manifest in the main repo's git dir (`<git-common-dir>/herdr-workspace/<name>.env`).

## Start

Decide the branch from the input:

| Input | Branch | Name |
|---|---|---|
| existing branch (`git branch -a`) | that branch (checked out as is) | ticket key in it, else the branch |
| ticket key (`PROJ-123`, `#123`, …) | new, per the project's branch convention (e.g. `PROJ-123-short-name`); title from your ticket tool (Jira MCP, `gh`, `glab`); none → ask the user for the short name | the key |
| free text | new, short slug of the text | the slug |

```bash
ws-start.sh <branch> [--ticket KEY] [--brief "<task or ticket text>"] [--breaks "<steps>|none"] [--review on|off] [--autonomous on|off] [--sub <repo>]...
```
- `--sub`: path, or folder name of a repo next to the main project; default `WS_SUBS`. Each sub repo gets a worktree
  with the same name and branch (existing branch → checked out, otherwise created from its `WS_BASE_BRANCH`).
- `--breaks`: planner review stops for this workspace (overrides `WS_PLAN_BREAKS`; "no breaks" → `none`).
- `--review`: code review after each implementer on/off for this workspace (overrides `WS_REVIEW`).
- `--autonomous`: a Decider agent answers instead of the user (overrides `WS_AUTONOMY`; "fully autonomous" → `on`).
- Every worktree runs `ws-setup.sh` in a Herdr tab "setup"; sub setups wait for the main one and get its exports
  (e.g. `API_URL`). The orchestrator starts at once in the main workspace (agent `orch-<slug>`) with the configured model.

Report the workspaces and that setup runs in the "setup" tabs (a first container or VM build — DDEV, Vagrant, Docker Compose — can take minutes).

## Manage

| Task | Command |
|---|---|
| Workspaces, setup state, exports (API URL, slot, port), config used | `ws-status.sh [name]` |
| Add a sub workspace | `ws-start.sh <branch> --name <name> --sub <repo>` (existing workspace: only the sub is added, no new orchestrator) |
| Remove a sub workspace | `ws-stop.sh <name> --sub <repo> [--ask\|--copy\|--delete]` |
| Reconfigure a worktree (config changed, API moved) | `ws-setup.sh` inside it (keeps e.g. its slot and containers) |
| Adopt a worktree set up another way | `ws-setup.sh` inside it |
| Restart a crashed or closed orchestrator (takes over) | `ws-start.sh <branch> --name <name> --orchestrator` |
| Remove the workspace | `ws-stop.sh <name> [--ask\|--copy\|--delete]` |

A sub repo shown with `config: none` gets a plain worktree; set it up with skill `herdr-workspace-config`.

`ws-stop.sh` refuses on uncommitted changes. Untracked files from `WS_KEEP`/`WS_KEEP_PATTERNS` that differ from the
main checkout: `ask` (default `WS_IGNORED_ON_REMOVE`) lists them and removes nothing (exit 2) — show the user the list
and rerun with their choice. It runs `ws-teardown.sh` (`WS_TEARDOWN`), removes subs first, closes the Herdr
workspaces and keeps all branches. Then the user tests locally on the branch.

## Findings
- Herdr has no setup/archive hooks, no repo registry and no parent/child worktrees: setup runs in a tab, teardown in `ws-stop.sh`, the manifest ties the workspace together.
- `herdr worktree create` makes a new branch; an existing branch is checked out with `git worktree add` and then `herdr worktree open --path`; both open a Herdr workspace labelled with the name.
- `herdr worktree remove` keeps the branch.
- A new worktree folder makes Claude Code ask "trust this folder": the agent is `blocked` until the user confirms it in Herdr. `ws-start.sh` waits for that (10 min) and then sends the prompt; never answer the dialog yourself.
