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

| Key | Meaning |
|---|---|
| `WS_BASE_BRANCH` | base for new branches (default `master`) |
| `WS_SUBS` | main project: default sub repos (path, or folder name next to the main project) |
| `WS_COPY` | untracked paths copied from the main checkout (no overwrite) |
| `WS_COPY_PATTERNS` | rsync include patterns copied anywhere in the tree, e.g. `STATUS.md ai-docs/***` |
| `WS_COPY_EXCLUDE` | names never copied (e.g. `worktrees`) |
| `WS_CLONE` | big dirs cloned copy-on-write where the filesystem allows (`cp --reflink=auto`, APFS `cp -c`), else copied (`vendor`, `node_modules`) |
| `WS_SETUP` / `WS_POST_SETUP` | commands run in the worktree after copying; env: `WS_MAIN`, `WS_CONFIG_DIR`, parent exports; append `KEY=value` to `$WS_EXPORT` to export for subs |
| `WS_TEARDOWN` | command run in the worktree before removal |
| `WS_KEEP` / `WS_KEEP_PATTERNS` | untracked paths/patterns offered for copy-back on removal (patterns default to `WS_COPY_PATTERNS`) |
| `WS_IGNORED_ON_REMOVE` | `ask` (default) / `copy` / `delete` |
| `WS_PLAN` | `worker` (default) / `self` / `none` |
| `WS_PLAN_BREAKS` | planner steps followed by a review stop, e.g. `speckit-specify speckit-plan`; empty = straight to tasks |
| `WS_PLAN_SKILL`, `WS_IMPLEMENT_SKILL` | skills/slash commands the workers run, in order; empty = none (brief only) |
| `WS_PLAN_BRIEF`, `WS_IMPLEMENT_BRIEF` | worker briefs, project rules on top of the skill (`<spec>` = spec path) |
| `WS_ORCHESTRATOR_AGENT` / `_MODEL` / `_EFFORT` / `_ARGS` | orchestrator: Herdr agent kind (default `claude`), model id, effort, extra native arguments |
| `WS_PLAN_AGENT` / `_MODEL` / `_EFFORT` / `_ARGS` | planner, same |
| `WS_IMPLEMENT_AGENT` / `_MODEL` / `_EFFORT` / `_ARGS` | implementer of this repo, same |
| `WS_REVIEW` | `on` / `off`: code review after each implementer (main project; per start `--review on\|off`) |
| `WS_REVIEW_SKILL`, `WS_REVIEW_BRIEF`, `WS_REVIEW_ROUNDS` | reviewer skills, brief (`<spec>` = spec path), max fix rounds (default 2) |
| `WS_REVIEW_AGENT` / `_MODEL` / `_EFFORT` / `_ARGS` | reviewer, same (a different model or agent than the implementer finds more) |
| `WS_AUTONOMY` | `on` / `off`: a Decider agent answers questions and approves the plan instead of the user (per start `--autonomous on\|off`); outward or risky decisions still go to the user |
| `WS_DECIDE_SKILL`, `WS_DECIDE_BRIEF` | Decider skills (e.g. `the-council`, used for real trade-offs only) and brief |
| `WS_ESCALATE` | extra topics that always go to the user, free text (e.g. "data migrations, pricing") |
| `WS_DECIDE_AGENT` / `_MODEL` / `_EFFORT` / `_ARGS` | Decider, same |
| `WS_PLANNER_AFTER` | command sent to the idle planner after its plan (default `/compact`; empty = none) |
| `WS_IMPLEMENTER_AFTER`, `WS_IMPLEMENTER_AFTER_WHEN` | command for idle implementers (default `/clear`) and when: `workstream` (default, after review fixes) / `task` |
| `WS_DECIDER_AFTER` | command for the Decider when its context grows (default empty) |

Agent kinds are Herdr's (`herdr agent` lists them: `claude`, `codex`, `gemini`, `opencode` …). Models are provider
model ids (e.g. `claude-opus-5-5`, `claude-sonnet-5-5`); empty = the agent's default. `_MODEL`/`_EFFORT` become native
flags for `claude` (`--model`, `--effort`) and `codex` (`-m`, `-c model_reasoning_effort=…`); for other kinds only
`--model`, so use `_ARGS` for the rest. Changes apply to workspaces started afterwards; a running orchestrator keeps
what it read.

## Backend settings

Both backends (Herdr 1 and herdr-core) share the same keys. Herdr has no per-repo setup or archive hooks and no per-repo workspace directory: worktrees land in
`~/.herdr/worktrees/<repo>/` (change with `[worktrees] directory` in `~/.config/herdr/config.toml`). `ws-start.sh`
runs the setup itself in a "setup" tab; `ws-stop.sh` runs the teardown. Remove workspaces with `ws-stop.sh`, not in
the Herdr UI, or the teardown (containers, VMs) is skipped.
