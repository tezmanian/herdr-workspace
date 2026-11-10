# 1. First workspace

## One-time setup (per project)

Open your agent in a Herdr pane, inside the project you work on most (the **main project**), and say:

> set up herdr-workspace

The agent runs `ws-doctor.sh`, asks which other repos belong to the project, writes a `workspace.env` (and a
`setup.sh`) for each and shows it to you before saving. Where it lives is your choice:

| Location | For |
|---|---|
| `<repo>/.herdr/workspace/` | shared with the team (commit it) |
| `<repo>/.agents/workspace/` | private to you (gitignore it) |
| `~/.config/herdr-workspace/projects/<repo>/` | personal, nothing in the repo |

Check at any time:

```console
$ $WS/ws-doctor.sh
ok    git found
ok    jq found
ok    rsync found
ok    backend: Herdr 1
ok    main api is a git repository
ok    config: /home/me/api/.agents/workspace
ok    base branch master exists
```

## A workspace for a ticket

> Workspace for PROJ-123

The agent turns the ticket into a branch (e.g. `PROJ-123-export-csv`, asking you for the short name if it cannot read
the ticket) and runs:

```bash
$WS/ws-start.sh PROJ-123-export-csv --ticket PROJ-123
```

What happens:
1. A worktree `~/.herdr/worktrees/api/PROJ-123` on the new branch (from `WS_BASE_BRANCH`).
2. Its setup (`WS_SETUP`) runs in the background; see it in the "setup" tab (Herdr 1) or with `hc ls` (core).
3. An orchestrator agent `orch-proj-123` starts in the worktree and plans the work. It may ask you things in its chat.

The first time, Claude Code asks whether to **trust the new folder**. That is your decision: confirm it in the
orchestrator's pane (`hc attach orch-proj-123` with herdr-core). The orchestrator's task is sent afterwards.

## A workspace from free text

> Workspace for "add rate limiting to the login endpoint"

Same thing with a branch made from the text (`add-rate-limiting-login`) and the text as the task.

## An existing branch

> Workspace for the branch `feature/csv-export`

The branch is checked out as is (no new branch); the name is the ticket key in it, else the branch with `/` as `-`.

## Only the worktree, no agent

```bash
$WS/ws-start.sh PROJ-123-export-csv --no-orchestrator
```
