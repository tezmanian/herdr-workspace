# herdr-workspace

Agent skills that turn [Herdr](https://herdr.dev) into a multi-repo, multi-agent workspace runner:

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

Requirements: `git`, `jq`, `rsync`, bash 3.2+ and one backend: [Herdr](https://herdr.dev) 1 (`herdr` CLI, 0.9+; your agent runs in a
Herdr pane, `HERDR_ENV=1`) or herdr-core (`hc`). `WS_BACKEND=herdr|core` forces one. Dependency dirs are cloned copy-on-write where the filesystem allows it, else copied.

```bash
git clone https://github.com/tezmanian/herdr-workspace ~/projects/herdr-workspace
~/projects/herdr-workspace/install.sh   # links the skills into ~/.claude/skills, ~/.agents/skills, ~/.codex/skills (those that exist)
```
Update with `git pull` (links follow). Then, in your main project inside Herdr, ask your agent:
**"set up herdr-workspace"** (skill `herdr-workspace-init`).

## Use

> Workspace for PROJ-123 with frontend

> Workspace for PROJ-123, fully autonomous

> Status of PROJ-123 · add frontend · tear down workspace PROJ-123

Scripts behind it (`skills/herdr-workspace/scripts/`): `ws-start.sh`, `ws-status.sh`, `ws-stop.sh`, `ws-setup.sh`,
`ws-doctor.sh`, `ws-agent.sh` (workers: names survive an orchestrator `/clear` via a registry `workers.tsv`; `prompt --report <file>` and `wait-report <file>` wait for a worker's `REPORT`/`QUESTION` line, not just the end of its turn, for 30 minutes at most unless `--timeout` says otherwise). Each script prints its usage with `--help`. More walk-throughs: [examples/](examples/).

## herdr-core and remote machines

With herdr-core every worker is a terminal that keeps running without any client attached. `--on <machine>` runs a
script on a saved machine (`hc machine add <ssh host>`), so a workspace can live and keep working on a remote box
while you are offline: `ws-start.sh PROJ-1 --on devbox --remote-dir ~/projects/api`, later `hc attach devbox/<name>`.
`--remote-dir` is a path on that machine (`~` = its home there). The remote machine needs `hc`, the agents, the repos
and these skills (`install.sh`; elsewhere: `WS_REMOTE_SCRIPTS=<scripts folder there>`).

## Tests

`tests/run.sh` checks the scripts in throwaway repos under a temp folder: argument handling, report waits, registry,
parent exports, and — when herdr-core runs (`hc server status`) — a whole start / status / stop cycle with worker
limits. It also runs `shellcheck` when that is installed. Nothing outside the temp folder is touched.

## How it fits Herdr

| Topic | How it is done |
|---|---|
| Repos and worktrees | no registry; sub repos = path or folder next to the main project; worktrees in `~/.herdr/worktrees/<repo>/<name>` (`[worktrees] directory`) |
| Setup and teardown | Herdr has no hooks: setup runs in a "setup" tab, teardown in `ws-stop.sh` (remove workspaces with it, not in the UI) |
| What belongs together | a manifest in the main repo's git dir (`herdr-workspace/<name>.env`) |
| Orchestration | plain agents: `herdr agent start/prompt --wait`, report files, notifications; state in `herdr-workspace/<name>/state.md` |

## Config

Per repo, first found wins: `<repo>/.herdr/workspace/workspace.env` (shared with the team),
`<repo>/.agents/workspace/workspace.env` (private), `~/.config/herdr-workspace/projects/<repo>/workspace.env`
(personal; override the base with `HERDR_WORKSPACE_HOME`). Template and key reference: `skills/herdr-workspace-config/`.
`WS_BASE_BRANCH` defaults to `master`; set it for repos with another base (`ws-doctor.sh` fails otherwise).
`WS_IMPLEMENT_MAX` and `WS_WORKERS_MAX` (main project) cap how many implementers / workers of all roles are alive at
once in a workspace; without them it is one implementer per repo or phase, plus planner, reviewers and decider as configured.

Environment switches: `WS_BACKEND` (`herdr`/`core`), `HERDR_WORKSPACE_HOME` (personal configs), `HERDR_WORKSPACE_STATE`
(worker registry outside a workspace, default `~/.local/state/herdr-workspace`), `HERDR_CONFIG_PATH` (Herdr's
`config.toml`, read for the worktree folder), `WS_REMOTE_SCRIPTS` (scripts folder on an `--on` machine),
`WS_REPORT_TIMEOUT` (seconds a report wait lasts, default 1800), `WS_WORKTREE_PATH` (worktree `ws-setup.sh` works on
instead of the current directory).

