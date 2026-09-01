# tmux-lanes

One skill that lets a coordinating agent run **real, interactive Claude Code
workers itself** — in detached tmux sessions — instead of asking a human to open
five windows and babysit them.

A *lane* is one live `claude` TUI in a tmux session, started on its own git
worktree, given a task prompt, and supervised: watched, poked when it stalls,
answered when it asks, and torn down only once its work is actually merged.

## The problem

Parallel agent work usually arrives in one of two unsatisfying shapes.

`claude -p` is headless. When it stops on a permission prompt, an overloaded API,
or an ambiguous acceptance criterion, there is nothing to poke and nobody can
attach and take over. The context is gone.

The human-driven alternative works but doesn't scale: you open a window per issue,
run `claude`, type the task, and glance at each one every few minutes. The
glancing is the job, and it's the part that should be automated.

A lane is the second shape with the glancing automated. It's the real TUI, so it
can be poked and it can be taken over — `tmux attach` and start typing, **Ctrl-b
d** to leave it running.

## How it works

**A per-lane Stop hook is the signal.** `start` writes a settings file for each
lane and passes it with `claude --settings`, wiring `Stop` →
`report turn-ended` and `UserPromptSubmit` → `report working`. When the agent
stops talking, the lead knows — deterministically, whether or not the worker
remembered to say so.

That indirection matters because a worker asked in prose to report its status
*will* write a perfect handoff into its own pane and then stop silently. And
because no `Stop` event fires during a long tool call, a lane 20 minutes into a
test sweep reads `working` rather than quiet-and-maybe-finished. Screen-reading
still covers what a hook cannot: a worker that crashed reports nothing, so `error`
and `dead` come from the pane and the process.

**`watch` fires on change, not on state.** It baselines every lane it's scoped to
and returns only when one of them differs from that baseline, so a lane parked in
`turn-ended` doesn't make every re-arm return instantly. Scope it with `--mine`
(via `TMUX_LANE_OWNER`) so it keeps covering lanes you add mid-run, and so it
never reports on another session's lanes.

**Rulings go on the ledger first.** `answer` comments the decision on the issue
*before* delivering it to the pane, and aborts delivery if the comment fails. A
keystroke into a tmux pane leaves no audit trail, so a ruling that exists only in
one agent's scrollback is invisible to whoever closes the issue later.

**`reap` has to prove the work is landed.** It refuses on a dirty worktree, on
commits not merged into the base ref, or when the base ref can't be resolved at
all — undeterminable is a refusal, not a pass. It measures against `origin/HEAD`
(override with `TMUX_LANE_BASE_REF`), deliberately *not* the lane's own upstream
branch, because comparing to a stale upstream produces false refusals and those
train you to reach for `--force`.

## Install

**Claude Code**

```
/plugin marketplace add pmcfadin/pmcfadin-skills
/plugin install tmux-lanes@pmcfadin-skills
```

**Codex**

```sh
codex plugin marketplace add pmcfadin/pmcfadin-skills
codex plugin add tmux-lanes@pmcfadin-skills
```

Needs `tmux` and the `claude` CLI on the machine running the lanes; `answer`
additionally needs `gh` authenticated with `repo` scope. See the
[repo README](../../README.md#install) for manual install, verification, and
updating.

## `scripts/tmux-lane.sh`

The whole tool is one dependency-free bash script. Run it with no arguments for
the full usage block.

```sh
tmux-lane.sh start  <name> --dir DIR --prompt TEXT [--issue N] [--yolo] [--model M]
tmux-lane.sh list                         # every lane: state, idle, issue, age, dir
tmux-lane.sh peek   <name> [-n LINES]     # what it's actually saying
tmux-lane.sh watch  --mine --timeout 1800 # block until a lane changes
tmux-lane.sh poke   <name> 'continue'     # types text + Enter
tmux-lane.sh key    <name> 2              # raw keys, for a choice dialog
tmux-lane.sh answer <name> --issue N '…'  # comment the ruling, then deliver it
tmux-lane.sh reap   <name>                # refuses unless the work is landed
tmux-lane.sh attach <name>                # hand off to the human
```

A lane's state is one of `working`, `gate-running`, `turn-ended`, `blocked`,
`landed`, `red`, `done`, `needs-input`, `error`, `idle`, `starting`, `unknown`, or
`dead`. The SKILL.md has the table of what each one means and what to do about it.

Configuration is all `TMUX_LANE_*` environment variables — `HOME` (state dir),
`CLAUDE` (CLI path), `PATH_STRIP` (drop wrapper-shim dirs from the lane's `PATH`),
`BASE_REF`, `OWNER`, `IDLE`, `SAMPLE`, `GC_DAYS`. `GH_HOST` is forwarded into each
lane when set, for GitHub Enterprise.

## `--yolo` is a real decision

`--yolo` passes `--dangerously-skip-permissions`. Without it a lane stops dead on
the first permission prompt and on every newly-seen MCP server, and stays stopped
until you poke it. With it, the lane runs any command in its worktree unreviewed.

Neither is the safe default. Pick per run, and have the agent say which it picked.

## Two rules that aren't optional

**One lane per worktree.** Two lanes sharing a directory will corrupt each other's
git state.

**Account for every lane before ending a turn.** Reaped, or named to the human
with its state and its issue. A forgotten lane holds a worktree and a model
session nobody is watching.

## License

Apache-2.0
