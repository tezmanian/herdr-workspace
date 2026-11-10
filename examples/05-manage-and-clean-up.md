# 5. Manage and clean up

Run these in any checkout of the main project.

## Where do things stand

```bash
$WS/ws-status.sh              # all workspaces of this project
$WS/ws-status.sh PROJ-123     # one
```
Shows each worktree, its branch, `ready` / `setup pending` / `setup FAILED`, the exports (API URL, slot, port) and the
config used. Workers: `$WS/ws-agent.sh list proj-123-` (name and state).

## Add or remove a repo later

> Add frontend to PROJ-123

```bash
$WS/ws-start.sh PROJ-123-export-csv --name PROJ-123 --sub web      # only the new sub is created
$WS/ws-stop.sh PROJ-123 --sub web --delete                         # remove just that sub workspace
```

## The setup changed or failed

Fix the config, then rerun inside the worktree; it keeps e.g. its slot and containers:

```bash
cd ~/.herdr/worktrees/api/PROJ-123 && $WS/ws-setup.sh
```
A sub whose parent setup failed stops waiting and says so; rerun the parent first.

## The orchestrator crashed or was closed

```bash
$WS/ws-start.sh PROJ-123-export-csv --name PROJ-123 --orchestrator
```
The new orchestrator finds its workers and reports (`ws-agent.sh list`, the files in
`<main repo>/.git/herdr-workspace/PROJ-123/`) and continues where things stand.

## Remove a workspace

> Tear down workspace PROJ-123

```bash
$WS/ws-stop.sh PROJ-123
```
- Refuses on uncommitted changes (commit or discard first).
- Untracked files from `WS_KEEP` that differ from the main checkout are **listed, nothing is removed** (exit 2). Rerun
  with `--copy` (into the main checkout) or `--delete`.
- Runs each repo's `WS_TEARDOWN` (stop containers/VMs), removes subs first, closes the workspaces. **Branches stay**, so
  you can test locally and push yourself.

Always remove with `ws-stop.sh`, not in the Herdr UI: only it runs the teardown. If a worktree folder was deleted by
hand, `ws-stop.sh` notices and just cleans the manifest.
