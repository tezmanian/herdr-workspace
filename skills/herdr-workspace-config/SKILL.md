---
name: herdr-workspace-config
description: "Creates or changes the herdr-workspace config of a repo (workspace.env + setup.sh): what a worktree copies and clones, its setup and teardown (containers or VMs such as DDEV, Vagrant or Docker Compose, npm, DB import), how a sub repo connects to the main project (API URL, ports), planner/implementer skills, briefs, agents and models. Use when the user says \"set up <repo> for workspaces\", \"workspace config\", \"planner should use Opus\", \"different model for the implementer\", or ws-status shows config: none."
---

# herdr-workspace config

`$WS` below = the `scripts/` folder of the herdr-workspace skill (e.g. `~/.claude/skills/herdr-workspace/scripts`).

One folder per repo: `workspace.env` (sourced by bash) plus the scripts it calls; `$WS_CONFIG_DIR` = that folder.
Lookup per repo, first found wins:
1. `<repo>/.herdr/workspace/workspace.env` — shareable with the team (commit it)
2. `<repo>/.agents/workspace/workspace.env` — private (gitignore it globally)
3. `${HERDR_WORKSPACE_HOME:-~/.config/herdr-workspace}/projects/<repo dir name>/workspace.env` — personal, for repos
   that should not carry their own

The main project's config also drives the orchestrator; each sub repo's config its own worktree and implementer.

## New repo

1. Copy the `template/` folder next to this file to the chosen folder.
2. Inspect the repo: gitignored files a checkout needs (`.env*`, config `*.dist`, agent rules), dependency dirs to
   clone (`vendor`, `node_modules`), how it finds its API, its dev server port, lock files `npm install` would touch,
   dev environment to start/stop (DDEV, Vagrant, Docker Compose …).
3. Fill `workspace.env` and `setup.sh`; a sub repo reads the parent's exports (`API_URL`, `WS_SLOT`) and gives
   itself a port per slot. Show the user the result before the first run.
4. Run `$WS/ws-setup.sh` inside the worktree; `ws-status.sh` shows `ready`.

## Keys

`template/workspace.env` is the reference: every key is there with a comment. In groups:

- **Checkout:** `WS_BASE_BRANCH`, `WS_SUBS` (main project: default sub repos, path or folder name next to it),
  `WS_COPY`, `WS_COPY_PATTERNS` (rsync include patterns, e.g. `STATUS.md ai-docs/***`), `WS_COPY_EXCLUDE`, `WS_CLONE`
  (big dirs, copy-on-write where the filesystem allows).
- **Setup and removal:** `WS_SETUP` (runs in the worktree; env `WS_MAIN`, `WS_CONFIG_DIR`, the parent's exports; append
  `KEY=value` to `$WS_EXPORT` to export for subs; chain commands with `;`), `WS_TEARDOWN`, `WS_KEEP`/`WS_KEEP_PATTERNS`
  (untracked files offered for copy-back), `WS_IGNORED_ON_REMOVE` (`ask`/`copy`/`delete`).
- **Orchestration (main project):** `WS_PLAN`, `WS_PLAN_BREAKS`, `WS_REVIEW*`, `WS_AUTONOMY`, `WS_DECIDE_*`, `WS_ESCALATE`,
  `WS_*_SKILL`, `WS_*_BRIEF` (`<spec>` = spec path), context hygiene `WS_PLANNER_AFTER`, `WS_IMPLEMENTER_AFTER(_WHEN)`,
  `WS_DECIDER_AFTER`. The scripts only read the first few; the orchestrator agent reads the rest from the file.
- **Agents per role** (`ORCHESTRATOR`, `PLAN`, `IMPLEMENT` per repo, `REVIEW`, `DECIDE`): `WS_<ROLE>_AGENT`, `_MODEL`,
  `_EFFORT`, `_ARGS`.

Agent kinds are Herdr's (`herdr agent` lists them: `claude`, `codex`, `gemini`, `opencode` …). Models are provider
model ids (e.g. `claude-opus-5-5`, `claude-sonnet-5-5`); empty = the agent's default. `_MODEL`/`_EFFORT` become native
flags for `claude` (`--model`, `--effort`) and `codex` (`-m`, `-c model_reasoning_effort=…`); for other kinds only
`--model`, so use `_ARGS` for the rest. Changes apply to workspaces started afterwards; a running orchestrator keeps
what it read. Both backends (Herdr 1 and herdr-core) share the same keys.
