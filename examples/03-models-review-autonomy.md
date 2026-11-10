# 3. Models, review and autonomy

All of it is `workspace.env` of the main project (plus `--review` / `--autonomous` / `--breaks` per start).

## Different model per role

```bash
WS_ORCHESTRATOR_MODEL="claude-sonnet-5-5"
WS_PLAN_MODEL="claude-opus-5-5"      # plan with the strongest model
WS_PLAN_EFFORT="high"
WS_IMPLEMENT_MODEL="claude-sonnet-5-5"
WS_REVIEW_AGENT="codex"              # another agent finds more than the one that wrote the code
WS_REVIEW_MODEL="gpt-5"
```
Just ask: *"planner should use Opus"* and the agent edits the file. Changes apply to workspaces started afterwards.
`WS_<ROLE>_ARGS` adds native arguments, e.g. `WS_IMPLEMENT_ARGS="--permission-mode acceptEdits"`.

## Review stops in the plan

With a planner skill that works in steps (for example speckit):

```bash
WS_PLAN_SKILL="speckit-specify speckit-clarify speckit-plan speckit-tasks"
WS_PLAN_BREAKS="speckit-specify speckit-plan"    # stop after these and wait for you
```
> Workspace for PROJ-123, no breaks

= `--breaks none` for this one workspace.

## Code review after each implementer

```bash
WS_REVIEW=on
WS_REVIEW_SKILL="ponytail-review"
WS_REVIEW_ROUNDS=2      # at most 2 fix rounds, the rest goes into the final report
```
or per start: *"Workspace for PROJ-123 with review"* (`--review on`).

## Fully autonomous

> Workspace for PROJ-123, fully autonomous

(`--autonomous on`.) A **Decider** agent answers the questions and approves the plan instead of you; every decision is
logged in `decisions.md` and listed in the final report. Things that are outward or hard to undo always come back to
you: push, merge requests, ticket changes, deploys, deleting data or branches, customer data, scope beyond the ticket.
Add your own topics:

```bash
WS_DECIDE_SKILL="the-council"                    # for real trade-offs only
WS_ESCALATE="database migrations, pricing, anything touching billing"
```
The orchestrator never pushes, in any mode.
