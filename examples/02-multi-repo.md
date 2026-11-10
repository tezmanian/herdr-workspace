# 2. Main project plus other repos

Say the API is the main project and the web frontend lives next to it (`~/projects/api`, `~/projects/web`).

## Config

Copy [configs/api](configs/api) to `~/projects/api/.agents/workspace/` and [configs/web](configs/web) to
`~/projects/web/.agents/workspace/` and adapt them. The idea:

- The **API** config lists the frontend in `WS_SUBS`, starts its dev environment in `setup.sh`, picks a free port slot
  and exports `API_URL` and `WS_SLOT`.
- The **web** config reads those exports (`API_URL`, `WS_SLOT`) and writes them into its own `.env.local`, with its own
  dev port per slot, so two workspaces never collide.

## Start

> Workspace for PROJ-123 with frontend

```bash
$WS/ws-start.sh PROJ-123-export-csv --ticket PROJ-123 --sub web
```

(`--sub` is a path or the folder name next to the main project; without it `WS_SUBS` is used.) Both worktrees get the
same name and branch. The web setup **waits** for the API setup and receives its exports:

```console
$ $WS/ws-status.sh PROJ-123
== PROJ-123
/home/me/.herdr/worktrees/api/PROJ-123  [PROJ-123-export-csv]  ready
  config: /home/me/projects/api/.agents/workspace
  API_URL=http://api-slot42.ddev.site
  WS_SLOT=42
  └ /home/me/.herdr/worktrees/web/PROJ-123  [PROJ-123-export-csv]  ready
      config: /home/me/projects/web/.agents/workspace
      DEV_PORT=3042
```

The orchestrator then runs one implementer per repo the plan touches, each in its own worktree, with that repo's agent,
model and brief.

## A repo without config

A sub repo with `config: none` gets a plain worktree. Ask: *"set up web for workspaces"* (skill
`herdr-workspace-config`) to give it one.
