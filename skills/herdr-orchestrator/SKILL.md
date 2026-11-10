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

| Key | Use |
|---|---|
| `WS_PLAN` | `worker` / `self` / `none` |
| `WS_PLAN_BREAKS` | planner steps followed by a review stop (prompt "Breaks"; `none` = no stops) |
| `WS_PLAN_SKILL`, `WS_PLAN_BRIEF` | planner skills (in order) and brief |
| `WS_IMPLEMENT_SKILL`, `WS_IMPLEMENT_BRIEF` | per repo: implementer skills and brief (`<spec>` = spec path) |
| `WS_REVIEW` | `on` / `off` (prompt "Review") |
| `WS_REVIEW_SKILL`, `WS_REVIEW_BRIEF`, `WS_REVIEW_ROUNDS` | reviewer skills, brief, max fix rounds (default 2) |
| `WS_AUTONOMY` | `on` / `off` (prompt "Autonomous"): a decider answers instead of the user, see below |
| `WS_DECIDE_SKILL`, `WS_DECIDE_BRIEF`, `WS_ESCALATE` | decider skills (e.g. `the-council`), brief, extra topics that still go to the user |
| `WS_*_AFTER` | context hygiene, see below |
| `WS_<ROLE>_AGENT`, `_MODEL`, `_EFFORT`, `_ARGS` | per role `PLAN`, `IMPLEMENT` (per repo), `REVIEW`, `DECIDE`: agent kind and native arguments |

Native arguments of a worker: `--kind <WS_x_AGENT>` and after `--` the output of
`source $WS/lib.sh; ws_agent_args <kind> <model> <effort> <extra args>` (claude: `--model M --effort E`; codex:
`-m M -c model_reasoning_effort="E"`). Empty model = the agent's default; effort only together with a model.
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
ws-agent.sh read <name> [lines]   |  wait <name> [--timeout SEC]  |  list [<slug>-]  |  focus <name>
```
`--cwd` is the worktree the worker is for (a sub repo's worktree for its implementer and reviewer); kind, model,
effort and args come from the worker's `WS_<ROLE>_*` keys. Reuse a worker for fixes and later tasks (`prompt` again)
instead of starting a new one. Never close workspaces, tabs, panes or terminals you did not create. Workers keep
running if you end; with herdr-core they also survive a closed ssh link on a remote machine.

**Waiting:** run each `ws-agent.sh prompt … --wait` as a background Bash command (`run_in_background`); you are
notified when it returns, so several workers (e.g. one implementer per repo) run in parallel and you never poll. After
a return, check `ws-agent.sh state <name>`:
- `idle` / `done` + its report file exists → finished (below).
- `blocked`, or `unknown` for a long time → it waits at a dialog (a worker in a fresh worktree usually starts with
  "trust this folder": the user's call, tell them via Attention): `ws-agent.sh read <name> 80`, then answer as under
  "Questions". Never type into a dialog on a guess.
- a timeout → inspect with `read` before resending; the prompt may have arrived.

**Report rule** (append to every worker spec): "When finished, write your result as Markdown to `$FILES/reports/<name>.md`
(outcome, evidence such as tests and commits, open points) and end your turn with the single line `REPORT <path>`.
If you need a decision, do not guess: write the question to that file, end with `QUESTION <path>` and wait." Read the
file, not the terminal scrollback.

## Attention

You may be one of several panes the user watches. When the user must act (review stop, clarify question,
"Approve plan?", a question you cannot answer, the final report): say it in your chat first, then
`$WS/ws-agent.sh notify "<workspace>: <what>"`, and for a worker's own chat
`$WS/ws-agent.sh focus <name>`. Keep `$FILES/state.md` current (plan task done, implementers running, review round,
open questions): a one-line-per-item status you rewrite at every step — it is what a resumed orchestrator reads.

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
1. `$WS/ws-agent.sh list <slug>-` → workers and who is `working`, `idle`, `blocked`.
2. Read `$FILES/state.md`, `$FILES/reports/` and `$FILES/decisions.md` → what is done, asked and answered.
3. Continue the flow at that point; answer blocked workers per "Workers". Tell the user in 3 lines where things stand.
