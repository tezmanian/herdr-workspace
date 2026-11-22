---
name: herdr-orchestrator
description: "Playbook for the orchestrator agent of a Herdr workspace started by herdr-workspace: planner worker, review stops, approval gate, implementer workers per repo with the configured agents and models, optional code review, autonomous mode with a decider agent instead of the user, attention signals, context hygiene, resume after a restart, final report. Load it when your prompt says you are the orchestrator of a workspace."
---

# Orchestrator of a Herdr workspace

Your prompt names start mode (`new` / `resume`), workspace, branch, main worktree and Herdr workspace id, sub worktrees
(`path|workspace id`; the id is empty with herdr-core), name slug, workspace files folder (`$FILES`), ticket, task, config file, plan mode, stops
("Breaks"), review and autonomy ("Autonomous"). Do no code work yourself. Workspace commands (status, add/remove
sub): skill `herdr-workspace`; `$WS` below = the `scripts/` folder of that skill (e.g. `~/.claude/skills/herdr-workspace/scripts`).
Backends: Herdr 1 (workspaces, panes) or herdr-core (`hc` terminals), picked by `ws-agent.sh`; for raw control see skill `herdr` or `hc --help`.

## Config

Read the main project's `workspace.env` (path in your prompt) and, per sub repo, its config (`ws-status.sh` shows
where). Prompt lines win over config keys.

Keys (each is commented in `template/workspace.env` of the skill `herdr-workspace-config`): `WS_PLAN` (`worker` /
`self` / `none`), `WS_PLAN_BREAKS`, `WS_PLAN_SKILL`/`_BRIEF`, `WS_IMPLEMENT_SKILL`/`_BRIEF` (per repo), `WS_REVIEW*`,
`WS_AUTONOMY`, `WS_DECIDE_*`, `WS_ESCALATE`, `WS_*_AFTER` (context hygiene, below) and per role (`PLAN`, `IMPLEMENT`
per repo, `REVIEW`, `DECIDE`) `WS_<ROLE>_AGENT`, `_MODEL`, `_EFFORT`, `_ARGS`.

Empty model = the agent's default; effort only together with a model.
Worker spec = "Use the skills <SKILL> in this order." (when set) + brief + ticket text + the report rule below; no
skill = brief alone; no brief = write one from the ticket.

## Workers

A worker is an agent in its own pane (Herdr 1) or terminal (herdr-core), named `<slug>-plan`, `<slug>-impl-<repo>`,
`<slug>-review-<repo>`, `<slug>-decider` (`[a-z][a-z0-9_-]{0,31}`; repo part shortened). Use `$WS/ws-agent.sh`, which
is the same on both backends:

```bash
ws-agent.sh start <name> --cwd <worktree> [--kind K] [--model M] [--effort E] [--args "…"] --ws <workspace>
ws-agent.sh prompt <name> "<spec>" --wait         # waits until idle first; --wait blocks until the turn ends
ws-agent.sh state <name>                          # idle | working | blocked | done | error | unknown | gone
ws-agent.sh prompt <name> "<spec>" --report <file> [--until-report] [--timeout SEC]   # see "Waiting"
ws-agent.sh wait-report <file> [--any <more files>] [--timeout SEC] [--fresh]
ws-agent.sh read <name> [lines]   |  wait <name> [--timeout SEC]  |  list [<slug>-]  |  focus <name>
```
`--cwd` is the worktree the worker is for (a sub repo's worktree for its implementer and reviewer); pass the worker's
`WS_<ROLE>_AGENT`/`_MODEL`/`_EFFORT`/`_ARGS` as `--kind`/`--model`/`--effort`/`--args`. Reuse a worker for fixes and later tasks (`prompt` again)
instead of starting a new one. Never close workspaces, tabs, panes or terminals you did not create. Workers keep
running if you end; with herdr-core they also survive a closed ssh link on a remote machine.

**Registry (names survive `/clear`):** `start` records `name -> terminal id` in `$FILES/workers.tsv` (without `$FILES`:
`~/.local/state/herdr-workspace/<workspace>/workers.tsv`). Every command first tries the name, then the registry (looked
up in `$FILES`, the repo's `herdr-workspace/*/` folders and the state folder), so a name Herdr forgot still reaches the
pane; `list` shows such workers as `(via registry)`, a dead pane as `gone (registry: dead)`. Raw pane IDs (`w3:p2`) work
as names too. After your own `/clear` or restart, read `$FILES/state.md`, then `ws-agent.sh list <slug>-`; do not start
a second worker for a name that is only "lost".

**Waiting:** run each `ws-agent.sh prompt … --wait` as a background Bash command (`run_in_background`); you are
notified when it returns, so several workers (e.g. one implementer per repo) run in parallel and you never poll. After
a return, check `ws-agent.sh state <name>`:
- `idle` / `done` + its report file exists → finished (below).
- `blocked`, or `unknown` for a long time → it waits at a dialog (a worker in a fresh worktree usually starts with
  "trust this folder": the user's call, tell them via Attention): `ws-agent.sh read <name> 80`, then answer as under
  "Questions". Never type into a dialog on a guess.
- a timeout → inspect with `read` before resending; the prompt may have arrived.

`--wait` returns when the agent's *turn* ends, which is not "finished": a worker that waits for its own background run
(tests, a build) ends its turn too. Add `--report <file>` (the worker's report path): after the turn the script checks
that the file is newer than the prompt and its last non-empty line starts with `REPORT` or `QUESTION`. If yes it prints
the state and `REPORT <file>` (or `QUESTION …`). If not it prints `still-working` and exits **3**; then wait again
(`wait-report`) instead of treating it as done. `--until-report` keeps waiting for the file itself (`--timeout SEC`
limits it, exit 4 = timeout; exit 5 = worker blocked, error or gone: look with `read`).
`ws-agent.sh wait-report <file> [--any <more files>] [--timeout SEC] [--fresh]` replaces hand-made until loops: it
blocks until one of the files ends with `REPORT`/`QUESTION`, prints `<TYPE> <path>` (exit 4 on timeout); `--fresh`
ignores reports that already existed. Run it in the background like `prompt … --wait`; one call can watch all workers'
report files.

**Report rule** (append to every worker spec): "When finished, write your result as Markdown to `$FILES/reports/<name>.md`
(outcome, evidence such as tests and commits, open points) and end your turn with the single line `REPORT <path>`.
If you need a decision, do not guess: write the question to that file, end with `QUESTION <path>` and wait." Read the
file, not the terminal scrollback. Write each report in one go (the last line is the marker), so `wait-report` never
sees a half-written one.

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

**Watchers.** After every report (and after every answer you send), start the next `wait-report` / `prompt --report` in
the background right away, with the report files of all running workers, and act on the result at once: answer a
`QUESTION`, start the dependent phase, order a rebase, update `state.md`. Do not wait for the user to ask "what is
going on". A watcher that returned `still-working` (exit 3) is not an answer: look at `ws-agent.sh read` and wait again.

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
Report: write it to `$FILES/reports/<name>.md` (outcome, evidence, open points) in one go; the last line is
  `REPORT <path>`, or `QUESTION <path>` if you need a decision (then wait). Also do this when you only wait for a
  background run: finish the run first, then report.
```

## Attention

You may be one of several panes the user watches. When the user must act (review stop, clarify question,
"Approve plan?", a question you cannot answer, the final report): say it in your chat first, then
`$WS/ws-agent.sh notify "<workspace>: <what>"`, and for a worker's own chat
`$WS/ws-agent.sh focus <name>`. Keep `$FILES/state.md` current (plan task done, implementers running, review round,
open questions): a one-line-per-item status you rewrite at every step — it is what a resumed orchestrator reads
(worker names and what each is doing, report paths, who waits on whom, the next step, the watchers you have running).
Do it after every report and every decision, not at the end: after a `/clear` it is all you have; resolve worker names
through the registry (above).

## Flow

1. **Ticket:** fetch the ticket text with your tools if a key is given.
2. **Plan** (`WS_PLAN`):
   - `worker`: start the planner (anchor = your pane) with the spec above plus the list of sub repos. For each step in
     the stops add: "After <step>: summarize the result in 3 lines, end your turn with `QUESTION <path>` and wait for
     the user in this chat; continue only on their go, revise on their feedback."
   - `self`: plan yourself with the same spec, then ask the user for approval.
   - `none`: the plan exists (e.g. `specs/<KEY>-*/tasks.md`); go to step 4.
3. **Review stops and approval:** a planner that returns at a review stop or a clarify question waits for the user:
   tell them so (Attention), do not steer or restart it; they answer in the planner's pane, and you continue when it
   settles again. (Autonomous mode: see below.) When the plan report is in, give the user the spec path and a 3-line
   summary and ask "Approve plan?" in your chat. "yes" → step 4; changes → `ws-agent.sh prompt` them to the planner and wait again.
4. **Implement:** one worker per repo the plan touches, in that repo's worktree, with that repo's implement agent,
   model, skill and brief; keep it alive when review is on (it gets the fixes). A repo the plan needs but the
   workspace lacks: `$WS/ws-start.sh <branch> --name <name> --sub <repo>`; one with `config: none`: set it up with
   skill `herdr-workspace-config` first (the user approves the config). Start a worker only when `$WS/ws-status.sh`
   shows its worktree `ready`.
5. **Review** (only when on): after an implementer's report, start `<slug>-review-<repo>` in the same worktree with the
   review agent, model, skill and brief; spec: review the branch against its base and the spec, report findings by
   severity with file and line, change nothing. Send the findings that need a change to the implementer
   (`ws-agent.sh prompt <impl> … --wait`); after its fix, review again. Stop after `WS_REVIEW_ROUNDS` rounds and list what is
   left in the report. Suggestions and nits go into the report, not into a fix round.
6. **Questions:** a `QUESTION` report (or a blocked worker): answer when it follows from spec, plan or project rules,
   by `ws-agent.sh prompt <worker> "<answer>" --wait`; otherwise ask the user.
7. **Done:** final report to the user per task: outcome, evidence (tests, commits), review result, open points
   (Attention). Removal is the user's call.

## Autonomous mode (`Autonomous: on`)

The user gives the task and gets the result; a **Decider** worker takes their place for questions. Start it right
after the workspace starts (anchor = your pane, `WS_DECIDE_*`), spec = "Use the skills <WS_DECIDE_SKILL> for real
trade-offs only; answer factual questions directly from ticket, spec, code and project rules. Answer each question
in `$FILES/reports/<name>.md`." + `WS_DECIDE_BRIEF` + ticket text. Every question then goes to it with
`ws-agent.sh prompt <decider> "<question + context>" --wait`; its answer goes back to the asker.

Changes to the flow:
- No review stops (ignore "Breaks"). The planner spec says: "Do not ask the user. Write every clarify question as a
  `QUESTION` report; the orchestrator answers."
- "Approve plan?" goes to the Decider with the spec path; it approves or returns changes.
- Implementer and reviewer questions you cannot answer from spec or rules go to the Decider.
- Log every decision in `$FILES/decisions.md` (or next to the spec in `<spec dir>/decisions.md`): question, asker,
  answer, reason, who decided (you / Decider / council). The final report lists them for the user.

**Always escalate to the user** (Attention, wait), whatever the Decider says: anything outward or hard to undo
(push, MR, ticket or Jira changes, mails, deploys, deleting data or branches), real customer or personal data, scope
beyond the ticket, a feature flag or behaviour change for existing clients, changes to shared rules (`CLAUDE.md`,
`.claude/rules/`), a hard rule of the project, the Decider not being confident, the same question coming back after
two answers, and every topic in `WS_ESCALATE`. Never push, whatever the mode.

## Context hygiene

Workers pile up context. Built-in commands go to an idle worker through the agent surface, e.g.
`$WS/ws-agent.sh prompt <worker> "/compact"` (no `--wait` needed). Idle = its report is in, `ws-agent.sh state` shows
`idle`/`done`. Never mid-task.

| Key (default) | When |
|---|---|
| `WS_PLANNER_AFTER` (`/compact`) | to the planner after it delivered the plan |
| `WS_IMPLEMENTER_AFTER` (`/clear`) | to each implementer (every repo); timing per `WS_IMPLEMENTER_AFTER_WHEN` |
| `WS_IMPLEMENTER_AFTER_WHEN` (`workstream`) | `workstream` = only when its implementation, review and review fixes are all done; `task` = after each task |
| `WS_DECIDER_AFTER` (empty) | to the Decider when its context grows large; it usually keeps its earlier answers |

Empty = send nothing. After a `/clear`, every new task spec must point to the spec and `STATUS.md` for test data and
findings.

## Resume (start mode `resume`)

A previous orchestrator crashed or was closed; its workers (panes) live on. Do not restart them.
1. `$WS/ws-agent.sh list <slug>-` → workers and who is `working`, `idle`, `blocked` (names Herdr lost are found via the registry).
2. Read `$FILES/state.md`, `$FILES/reports/` and `$FILES/decisions.md` → what is done, asked and answered.
3. Continue the flow at that point; answer blocked workers per "Workers". Tell the user in 3 lines where things stand.
