---
name: herdr-workspace-init
description: "One-time setup of herdr-workspace for a project: checks tools, picks the sub repos, creates each repo's config and verifies everything with ws-doctor. Use when the user says \"set up herdr-workspace\", \"init herdr workspace\", \"set up workspaces for this project\", \"/herdr-workspace-init\", or ws-doctor reports FAIL. Requires HERDR_ENV=1."
---

# Set up herdr-workspace for a project

The repo the agent runs in is the main project. `$WS` = the `scripts/` folder of the herdr-workspace skill (e.g.
`~/.claude/skills/herdr-workspace/scripts`). Ask before anything outward or outside the repos involved.

1. **Check:** `$WS/ws-doctor.sh` — fix every `FAIL` before going on.
   - Tools missing (`herdr`, `git`, `jq`, `rsync`) or not inside a Herdr pane: tell the user how to fix it; do not install yourself.
   - Skills not available to another agent the user works with: `install.sh` of the herdr-workspace repo links them
     into that agent's skills folder.
2. **Repos:** ask which sub repos belong to the project (admin UI, frontend, app …) and where they are (folder next to
   the main project, or a path). Herdr needs no registration.
3. **Worktree directory:** Herdr puts all worktrees under `~/.herdr/worktrees/<repo>/<name>`. Only if the user wants
   another place, set `[worktrees] directory` in `~/.config/herdr/config.toml` (global, all projects), then `herdr server reload-config`.
4. **Configs:** per repo with skill `herdr-workspace-config` — where it lives (`.herdr/workspace/` to share with the
   team, `.agents/workspace/` private, `~/.config/herdr-workspace/projects/<repo>/` personal), what it copies, clones,
   sets up, tears down, how a sub repo reaches the main project. Main project: also planner, implementer, review,
   autonomy, models. Set `WS_SUBS` to the default sub repos. Show the user each config before saving.
5. **Verify:** `$WS/ws-doctor.sh` until no `FAIL` remains; explain each `warn`. Optional dry run: start a throwaway
   workspace (`ws-start.sh ws-smoke-test --no-orchestrator`), check `ws-status.sh`, remove it with
   `ws-stop.sh ws-smoke-test --delete` and delete the branch.
6. **Report:** what is set up and how to start: "Workspace for <ticket>" (skill `herdr-workspace`). Note that
   workspaces must be removed with `ws-stop.sh`, not in the Herdr UI (teardown).
