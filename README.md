# herdr-workspace

Agent skills that turn [Herdr](https://herdr.dev) into a multi-repo, multi-agent workspace runner (the Herdr
counterpart of [orca-workspace](../orca-workspace)):

- **One command per ticket:** a worktree of the main project on the ticket's branch, worktrees in the other
  repos it touches (admin UI, frontend, app), each set up from the repo's own config and wired to the main one (API
  URL, ports, own slot for DDEV, Vagrant, Docker Compose …).
- **An orchestrator agent** that runs planner, implementers (one per repo), code review and, optionally, a Decider
  that answers questions instead of you — with configurable agents and models per role. Workers are ordinary Herdr
  agents in panes you can watch and talk to.
- **Per-project config** in a plain `workspace.env` per repo; nothing project-specific in the skills.

| Skill | For |
|---|---|
| `herdr-workspace-init` | one-time setup of a project: sub repos, configs, `ws-doctor` |
| `herdr-workspace` | start, status, add/remove sub workspaces, remove a workspace |
| `herdr-orchestrator` | playbook the orchestrator agent loads |
| `herdr-workspace-config` | create or change a repo's config; reference of all keys |

## Install

Requirements: `git`, `jq`, `rsync`, bash and one backend: [Herdr](https://herdr.dev) 1 (`herdr` CLI, 0.9+; your agent runs in a
Herdr pane, `HERDR_ENV=1`) or herdr-core (`hc`). `WS_BACKEND=herdr|core` forces one. Dependency dirs are cloned copy-on-write where the filesystem allows it, else copied.

```bash
git clone <this repo> ~/projects/herdr-workspace
~/projects/herdr-workspace/install.sh   # links the skills into ~/.claude/skills, ~/.agents/skills, ~/.codex/skills (those that exist)
```
Update with `git pull` (links follow). Then, in your main project inside Herdr, ask your agent:
**"set up herdr-workspace"** (skill `herdr-workspace-init`).

## Use

> Workspace for PROJ-123 with frontend

> Workspace for PROJ-123, fully autonomous

> Status of PROJ-123 · add frontend · tear down workspace PROJ-123

Scripts behind it (`skills/herdr-workspace/scripts/`): `ws-start.sh`, `ws-status.sh`, `ws-stop.sh`, `ws-setup.sh`,
`ws-teardown.sh`, `ws-doctor.sh`.

## herdr-core and remote machines

With herdr-core every worker is a terminal that keeps running without any client attached. `--on <machine>` runs a
script on a saved machine (`hc machine add <ssh host>`), so a workspace can live and keep working on a remote box
while you are offline: `ws-start.sh PROJ-1 --on devbox --remote-dir ~/projects/api`, later `hc attach devbox/<name>`.
The remote machine needs `hc`, the agents, the repos and these skills (`install.sh`).

## Differences to orca-workspace

| Orca | Herdr |
|---|---|
| repos registered in Orca, workspace dir per repo | no registry; sub repos = path or folder next to the main project; worktrees in `~/.herdr/worktrees/<repo>/<name>` (`[worktrees] directory`) |
| setup / archive hooks | none: setup runs in a "setup" tab, teardown in `ws-stop.sh` (remove workspaces with it, not in the UI) |
| parent/child worktrees | a manifest in the main repo's git dir (`herdr-workspace/<name>.env`) |
| `orca orchestration` (runs, tasks, gates, board) | plain agents: `herdr agent start/prompt --wait`, report files, notifications; state in `herdr-workspace/<name>/state.md` |

## Config

Per repo, first found wins: `<repo>/.herdr/workspace/workspace.env` (shared with the team),
`<repo>/.agents/workspace/workspace.env` (private), `~/.config/herdr-workspace/projects/<repo>/workspace.env`
(personal; override the base with `HERDR_WORKSPACE_HOME`). Template and key reference: `skills/herdr-workspace-config/`.

