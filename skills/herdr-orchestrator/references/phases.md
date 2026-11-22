# Phases, collecting branch and the worker spec template

Reference for the skill `herdr-orchestrator` (`$FILES`, `ws-agent.sh` and the report rule are explained there).

## Several phases with dependencies and a collecting branch

For a plan with phases that build on each other (typical for a milestone with several features), use **one collecting
branch and one pull request**, not one PR per phase.

1. Create the collecting branch (`feat/<milestone>`) from the base and push it once. Each phase gets its own branch
   and worktree, started in dependency order (`ws-start.sh … --sub` / `ws-agent.sh start`); a phase starts from the
   collecting branch as soon as the phases it depends on are in it.
2. A finished phase is merged **by its own worker**: `git merge --no-ff <phase-branch>` into the collecting branch and
   push. A branch can be checked out in one worktree only, so the worker merges on a detached HEAD and pushes by ref:
   ```bash
   git fetch origin && git checkout --detach origin/<collecting-branch>
   git merge --no-ff <phase-branch> -m "merge: <phase>"
   # gates again if the merge was not trivial, then:
   git push origin HEAD:refs/heads/<collecting-branch>
   ```
   A rejected push means someone else merged first: fetch, redo the merge, push again.
3. Tell the other running workers after each merge: "Rebase onto `origin/<collecting-branch>`, rerun your gates,
   continue." Do it per worker with `ws-agent.sh prompt … --report` (they report when done); never mid-test-run.
4. The merge into `main` (or the base) is for the human only. The final report names the collecting branch and its PR.

**Isolation per worker.** Each worker gets its own ports, its own Postgres (or database) and its own Compose project
name (`-p <slug>-<phase>`), so parallel gate runs cannot collide; put the values in its spec.

**Load.** At most **2** parallel full gate runs (build, all tests, containers); further workers wait or only write
code. Say in the spec which worker may run the full gates now, and release the next one when a report arrives.

## Spec template for a worker

Fill it per worker; the planner and reviewer variants drop what does not apply.

```text
Worktree: <path> (branch <phase-branch>, base <collecting-branch or main>). Work only there.
Skills: use <skills> in this order. <brief, ticket or spec path, STATUS.md for test data and findings>
Task: <what, with the done criteria>
Commits: small and thematic, `<type>(<area>): <summary>` in the project's language; never push except as stated below.
Gates before every report: <build / lint / typecheck / tests, the exact commands>; at most 2 workers run the full
  gates at once, you are <allowed | not allowed> to now.
Ports and services: <ports, database, Compose project name for this worker>.
Merge: <none | after done: --no-ff into <collecting-branch> on a detached HEAD, push HEAD:refs/heads/<collecting-branch>>.
Never touch: other workers' panes and worktrees, the base branch, shared rules.
Report: <the report rule from SKILL.md, with the real report path>
```
