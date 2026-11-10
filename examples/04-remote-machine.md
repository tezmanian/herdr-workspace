# 4. A workspace on a remote machine (herdr-core)

Workers are herdr-core terminals, so they keep running with nothing attached. Start a workspace on a box, close your
laptop, look in later.

## Once

On your machine, add the box (ssh):

```bash
hc machine add devbox          # an ssh host name from ~/.ssh/config
hc machine ls
```
On the box: `hc` (herdr-core), your agents (`claude` …), the repos, and these skills (`./install.sh` from a clone of
this repo). Then check from here:

```bash
$WS/ws-doctor.sh --on devbox --remote-dir ~/projects/api
```

## Start

```bash
$WS/ws-start.sh PROJ-123-export-csv --ticket PROJ-123 --sub web --on devbox --remote-dir ~/projects/api
```
`--remote-dir` is the main project **on the box**. Worktrees, setup, orchestrator and workers all run there.

## Look in, answer, leave

```bash
hc exec --on devbox hc ls --label ws=PROJ-123   # what is running there (setup terminals su-…, orch-…, workers)
hc attach devbox/orch-proj-123                  # talk to the orchestrator (ctrl+\ detaches)
hc read devbox/orch-proj-123                    # just read its screen
```
Remote addresses are `machine/name` or `machine/t7` (see `hc attach --help`; this form is from the hc help and not yet tried against a real box).

The "trust this folder" question of a fresh worktree has to be answered by you the first time (attach, confirm,
detach). Status and removal work the same way:

```bash
$WS/ws-status.sh --on devbox --remote-dir ~/projects/api
$WS/ws-stop.sh PROJ-123 --delete --on devbox --remote-dir ~/projects/api
```
`hc exec` ends a command after 10 minutes at most, so a very slow teardown (e.g. `ddev delete` of a huge project) can
be cut off: run `ws-stop.sh` on the box itself then.
