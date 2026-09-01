---
name: tmux-lanes
description: Use when a coordinating agent should run one or more real Claude Code workers itself instead of asking the human to open windows — starts each in a detached local tmux session, sends it a slash command or task prompt, watches it, pokes it when it stalls on a prompt or API error, and tears it down when its work is landed. Use for local parallel lanes on this machine.
---

# tmux lanes

A lane is a **real, interactive Claude Code process** in a detached tmux session.
It is what the human used to do by hand: open a window, run `claude`, type a task
prompt, glance at it, say "continue" when it stalls, close it.

`claude -p` is deliberately *not* used. A headless run cannot be poked, and a
human cannot attach and take over. Both are the point of a lane.

## Set `TOOL` first

Every command below is `$TOOL <subcommand>`. Set it to
`<the directory you loaded this SKILL.md from>/scripts/tmux-lane.sh`:

```bash
TOOL="$CLAUDE_PLUGIN_ROOT/skills/tmux-lanes/scripts/tmux-lane.sh"  # Claude Code plugin
TOOL=~/.claude/skills/tmux-lanes/scripts/tmux-lane.sh              # manual, Claude Code
TOOL=~/.codex/skills/tmux-lanes/scripts/tmux-lane.sh               # manual, Codex
```

Requires `tmux` and the `claude` CLI on this machine. `answer` additionally needs
`gh`. Run `$TOOL` with no arguments for the full usage block, including the
`TMUX_LANE_*` environment variables.

## The loop

### 1. Start a lane

```bash
$TOOL start <name> --dir <worktree> --prompt '<slash command or task>' --yolo
```

- `<name>` is short and stable — usually the issue number. Session is `lane-<name>`.
- `--dir` is the lane's **own worktree**, never the primary checkout.
- `--issue N` records the tracker issue in the lane's metadata, so `answer`
  knows where to log a ruling and a replacement lead can tell what the lane is for.
- `--yolo` adds `--dangerously-skip-permissions`. **Without it, the lane will
  stop dead on the first permission prompt and on a new MCP server, and stay
  stopped until you poke it.** With it, the lane can run any command in that
  worktree unreviewed. Choose deliberately; say which you chose.
- Exits `3` with the pane text if a startup dialog blocks it (folder trust, a
  newly-seen MCP server). Answer it with `key`, **reading the pane to see which
  kind of dialog it is**, then send the prompt with `poke`:
  - arrow-selected list — `❯` marks the current option, no numbers:
    `$TOOL key <name> Down Enter`
  - numbered list (`1.` / `2.`): `$TOOL key <name> 2`

  Do not reach for `2` reflexively. The folder-trust dialog is arrow-selected and
  its options put **"No, exit" first**, so a stray keystroke that does nothing
  leaves the lane parked, and a blind `Enter` quits it.
- Refuses to start over a live session. Never work around that.

### 2. Watch

```bash
$TOOL list                  # all lanes: state, idle, age, dir
$TOOL state <name>          # one lane
$TOOL peek  <name> -n 40    # what it is actually saying
```

States, and what each means:

| state | meaning | what to do |
| --- | --- | --- |
| `working` | pane moving, or a long tool call in flight | nothing |
| `gate-running` | worker announced a long gate | **nothing** — does not wake the lead |
| `turn-ended` | **Stop hook fired** — the agent stopped talking | `peek`, then judge |
| `blocked` | worker reported a question | `peek` for context, then `answer` |
| `landed` | worker reported its commit is on the base branch | verify, then `reap` |
| `red` | worker reported a failing gate | `peek`; usually let it fix forward |
| `done` | worker reported finished | verify against the issue, then `reap` |
| `needs-input` | a prompt is on screen and nothing is moving | `key` the answer |
| `error` | API error / rate limit / crash text, not moving | `poke` "continue" |
| `idle` | pane static ≥45s and nothing reported | hook missing — `peek` and judge |
| `starting` | no pane samples yet | nothing |
| `unknown` | sampler died | `$TOOL resample <name>` |
| `dead` | session gone | check git state in the lane's `dir` |

### `turn-ended` is the signal that matters

Every lane gets its own `Stop` hook, written by `start` and passed with
`claude --settings`. When the agent stops talking, the hook fires
`report turn-ended`. You do not have to ask the worker to cooperate, and it
cannot forget.

This is a correction, not a nicety: a worker given a reporting contract in its
brief wrote a perfect handoff into the pane and stopped silently anyway.
**Prose compliance is not a signal.**

Crucially, **no Stop event fires during a long tool call.** A lane running a
22-minute gate is `working`, not quiet-and-maybe-finished. That distinction is
what stops the lead burning round trips on a lane that is fine.

`turn-ended` does not say *why* it stopped. `peek` and judge: finished, asking,
or stuck. That judgement is the lead's job.

A worker's own report takes precedence — the Stop hook that fires straight after
will not overwrite `blocked`, `done`, `landed`, or `red`. Encourage it in the
brief, but never depend on it.

**Tell every worker to announce a long gate.** One line in the brief removes most
of the lead's remaining peeks — `start` exports `TMUX_LANE_TOOL` into the lane so
the worker does not need to know where this script is installed:

> Before starting anything that runs longer than about two minutes, run
> `"$TMUX_LANE_TOOL" report gate-running '<what and how long>'`.

A report is cleared by exactly one thing: the lead acting on it (`poke` / `key` /
`answer`). It is **never** invalidated by pane motion. That rule used to exist and
was the root cause of healthy lanes reading `idle`: a lane whose own 700-second
gate kept printing after its turn ended had its report discarded, and fell through
to screen-reading. The worker's `UserPromptSubmit` hook sets `working` the moment
it is given something to do.

A hook cannot cover a worker that fell over — a dead worker reports nothing.
`error` and `dead` come from screen-reading and process state. Both layers needed.

### 3. Block until something changes

Set `TMUX_LANE_OWNER` once, before starting anything, then scope by owner:

```bash
export TMUX_LANE_OWNER=run3
$TOOL watch --mine --timeout 1800        # run this with run_in_background
$TOOL wait <name> --until working --timeout 90
```

**Use `--mine`, not a hand-typed list of names.** Both scope correctly, but
`--mine` keeps working when you add a lane mid-run — a hand-listed set silently
stops covering the new one. Never run `watch` unscoped: it reports on every lane
on the machine, including another session's.

**`watch` fires on CHANGE, not on state.** It baselines every lane when it starts
and returns only when one differs from its baseline. Re-arming re-baselines, so a
lane you have already seen sitting in `turn-ended` stays quiet instead of making
every re-arm return instantly — which is what breaks multi-lane watching
otherwise.

Two consequences worth internalising:

- If a lane already needs attention when `watch` starts, it prints
  `^ ALREADY needs attention ... will NOT re-fire`. **Handle it before re-arming**,
  or you have just silenced an unanswered question.
- A *new* message on an already-`blocked` lane does fire — the fingerprint
  includes the report text, not just the state.

**Run it backgrounded with a long timeout.** A long timeout costs no
responsiveness, because it returns the moment something changes; it only controls
how often you wake when nothing is happening. Foreground calls are hard-killed at
120s by the Bash tool. Backgrounded at 1800, a three-hour run wakes the lead a
handful of times instead of ~120.

A timeout exits **0** with `attention=none`, because "nothing needed you" is the
good outcome, not a failure.

`wait --until <state>` covers the reverse case: block until a lane goes back to
`working` after you poke it. Plain `wait` returns as soon as the lane stops being
`working`. This is a legitimate blocking watcher, not a spin-wait on a subagent —
a tmux pane has no notification channel. Its default timeout stays under the 120s
Bash ceiling, so re-invoke it across turns rather than raising it.

`--idle` is the stillness threshold that counts as done. Lower it (15–20s) for
snappier turnaround; raise it if lanes run long silent commands like a 260s test
sweep.

### 4. Unstick

```bash
$TOOL poke <name> 'continue'        # types text + Enter
$TOOL key  <name> Enter             # raw keys: 1 / 2 / Enter / C-c / Escape
```

Before poking, `peek` first. Poking a lane that is mid-thought inserts a stray
message into its context. Two stalls have different fixes:

- **API error / overloaded** → `poke <name> 'continue'`.
- **Permission or choice dialog** → `key`, not prose. Numbered options take
  `key <name> 2`; an arrow-selected list (`❯` on the current line, no numbers)
  takes `key <name> Down Enter`. Check the pane; guessing can pick the wrong one.

If a lane has stalled twice on the same thing, attach and look yourself rather
than poking a third time.

### 4b. Answer a question — the lead's actual job

A `blocked` lane is waiting on a **decision**, not a keystroke. Decide it from
the source of truth — the approved spec, the issue's acceptance criteria, the
design document — never by inventing an answer, and never by letting the worker
decide something it escalated.

```bash
$TOOL peek   <name> -n 40
$TOOL answer <name> --issue 1234 'AC-7 wins. AC-3 is scoped to the legacy path; do not widen it.'
```

`answer` comments the ruling on the issue **first**, then delivers it to the
pane. If the comment fails, nothing is delivered and it exits 1.

That order is the whole point. A keystroke into a pane leaves no audit trail, and
the tracker is the ledger — a ruling that exists only in one agent's scrollback is
invisible to every later pass, including the one that closes the issue. Use plain
`poke` for mechanics ("continue", "rerun the gate"); use `answer` for anything
that decides scope, semantics, or a conflict.

`--no-issue` exists for a ruling that genuinely is not a decision. It prints a
warning. If you reach for it on a real conflict, you are breaking the ledger.

### 5. Reap

```bash
$TOOL reap <name>            # refuses if the worktree is dirty or unpushed
$TOOL reap <name> --force    # only when you have verified there is nothing to lose
```

`reap` refuses if the lane's worktree is dirty, or if it has commits **not merged
into the base ref**, or if the base ref cannot be resolved at all — undeterminable
is a refusal, not a pass. The base ref is whatever `origin/HEAD` points at,
overridable with `TMUX_LANE_BASE_REF`.

It deliberately does **not** compare against the lane's own upstream branch. That
version refused a clean, fully-merged worktree because its branch was "21 commits
ahead of upstream", and a false refusal is worse than none: it pushes the operator
onto `--force`, which is the button that destroys work.

A refusal is real information. Report it, leave the session running, and only
`--force` after checking `git status --porcelain` and `git log <base>..HEAD`
yourself. Say which you did.

## Rules

- **Account for every lane before ending the turn.** Each one is either reaped,
  or named to the user with its state and its issue. A forgotten lane holds a
  worktree and a model session nobody is watching.
- **One lane per worktree.** Two lanes in one directory will corrupt each
  other's git state.
- **A lane still owes the repository's gates.** It is a normal Claude Code
  session under the repo's `AGENTS.md` / `CLAUDE.md`: issue, branch pushed before
  the first edit, review gate, and it does not close its own issue. Lanes make
  the work parallel; they do not shorten the contract.
- **Never `tmux kill-session` directly.** That skips the dirty/unpushed check.
- **Report a table, not a pane dump.** Lane, issue, state, next action.

## Human hand-off

```bash
$TOOL attach <name>     # prints the tmux attach command
```

The human attaches, sees the whole session, and can take over by typing. Detach
with **Ctrl-b d** and the lane keeps running. This is the escape hatch that
makes lanes safe to trust.

## Known behaviour

- `claude` on `PATH` may be a wrapper shim (some terminal and IDE wrappers put
  one ahead of the real binary), so the tool prefers `~/.local/bin/claude`.
  Override with `TMUX_LANE_CLAUDE`. To keep shim directories out of the lane's
  own `PATH` as well, set `TMUX_LANE_PATH_STRIP` to a colon-separated list of
  substrings to drop; nothing is stripped by default.
- Readiness is detected from an empty `❯` input line, **not** the
  `? for shortcuts` footer — a custom statusline replaces that footer entirely.
- `GH_HOST` is forwarded into the lane when set, for GitHub Enterprise hosts,
  because a lane will run `gh`.
- Lane bookkeeping lives in `~/.claude/tmux-lane/state/` (`TMUX_LANE_HOME`).
  Nothing there is authoritative; git and the issue tracker are.
