#!/usr/bin/env bash
# tmux-lane — start and supervise interactive Claude Code workers in detached
# tmux sessions, so a coordinating agent can do what a human does in a spare
# window: start a worker on a task, watch it, poke it when it stalls, clean up.
#
# Deliberately interactive (the real TUI), not `claude -p`: the whole point is
# that a stalled lane can be poked, and a human can attach and take over with
# full context.
#
# Three design rules, each of which came from a lane run that went wrong:
#   1 A worker will NOT self-report reliably on instruction alone — it can write
#     a perfect handoff into the pane and still stop silently. So every lane gets
#     its own Stop hook via `claude --settings`, which fires `report turn-ended`
#     deterministically. Prose compliance is not a signal.
#   2 `reap` measures "is this work landed" against the repo's base ref, not
#     against the lane's own upstream branch. Comparing to a stale upstream
#     refuses clean, fully-merged worktrees, and a false refusal is worse than
#     no check: it trains the operator to reach for --force.
#   3 One background sampler per lane is the ONLY writer of pane state. Readers
#     never write, so two observers cannot corrupt each other's idle timers, and
#     `idle` means "since the pane last changed" rather than "since someone
#     asked".
#
# Subcommands:
#   start  <name> --dir DIR --prompt TEXT [--issue N] [--yolo] [--model M] [--no-send]
#   list   [lanes...]                 # includes DEAD lanes; state dir is the source
#   peek   <name> [-n LINES]
#   state  <name>
#   poke   <name> TEXT                # types TEXT + Enter
#   key    <name> KEY...              # raw tmux keys, e.g. Enter / C-c / 1
#   answer <name> [--issue N] TEXT    # lead ruling: comments the issue, THEN pokes
#   report [--lane N] <STATE> [msg]   # called BY a worker or its Stop hook
#   wait   <name> [--timeout S] [--idle S] [--until STATE]
#   watch  [lanes...] [--timeout S] [--mine]
#   reap   <name> [--force]
#   attach <name>
#   sample <name>                     # internal: the per-lane sampler loop
#
# Environment:
#   TMUX_LANE_HOME      state directory        (default ~/.claude/tmux-lane)
#   TMUX_LANE_CLAUDE    path to the claude CLI (default: autodetected)
#   TMUX_LANE_PATH_STRIP  colon-separated substrings; PATH entries matching any of
#                       them are kept out of the lane's environment (default none)
#   TMUX_LANE_BASE_REF  ref reap measures against (default: origin's HEAD branch)
#   TMUX_LANE_OWNER     tag lanes so `--mine` can scope to this session's lanes
#   TMUX_LANE_IDLE      seconds of stillness that counts as idle  (default 45)
#   TMUX_LANE_SAMPLE    sampler interval in seconds               (default 10)
#   TMUX_LANE_GC_DAYS   age at which reaped metadata is deleted   (default 14)
#   GH_HOST             forwarded into the lane if set (GitHub Enterprise)
set -uo pipefail

ROOT="${TMUX_LANE_HOME:-$HOME/.claude/tmux-lane}"
STATE="$ROOT/state"
IDLE_SECS="${TMUX_LANE_IDLE:-45}"
SAMPLE_SECS="${TMUX_LANE_SAMPLE:-10}"
PANE_LINES=60
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
mkdir -p "$STATE"

die() { printf 'tmux-lane: %s\n' "$*" >&2; exit 1; }
sess_of() { printf 'lane-%s' "$1"; }
alive() { tmux has-session -t "=$(sess_of "$1")" 2>/dev/null; }
meta() { sed -n "s/^$2=//p" "$STATE/$1.meta" 2>/dev/null; }

# NOTE: has-session accepts tmux's '=exact' target syntax but capture-pane and
# send-keys do NOT — they silently fail with "can't find pane: =name". Lane
# names are 'lane-' prefixed, so a plain target is unambiguous enough.
pane() {
  tmux capture-pane -p -J -t "$(sess_of "$1")" 2>/dev/null | sed -e 's/[[:space:]]*$//'
}
pane_hash() { pane "$1" | tail -n "$PANE_LINES" | shasum | cut -d' ' -f1; }

# The PATH a lane gets, with wrapper-shim directories removed — a lane should run
# the real CLI, not a wrapper that intercepts it. Nothing is stripped by default;
# set TMUX_LANE_PATH_STRIP to a colon-separated list of substrings if your
# environment injects shims. Some terminal/IDE wrappers put a shim dir ahead of
# the real one, which is how a lane ends up running a wrapped `claude` or `git`.
clean_path() {
  local out="" e strip IFS=:
  local -a pats=()
  for strip in ${TMUX_LANE_PATH_STRIP:-}; do
    [ -n "$strip" ] && pats+=("$strip")
  done
  for e in ${PATH:-}; do
    local skip=0 p
    for p in ${pats[@]+"${pats[@]}"}; do
      case "$e" in *"$p"*) skip=1; break ;; esac
    done
    [ "$skip" = 1 ] && continue
    out="${out:+$out:}$e"
  done
  printf '%s' "$out"
}

# `claude` on PATH is often a wrapper, so prefer the real binary. Resolution
# order: explicit override, the usual install location, then a cleaned PATH.
find_claude() {
  if [ -n "${TMUX_LANE_CLAUDE:-}" ]; then printf '%s' "$TMUX_LANE_CLAUDE"; return; fi
  if [ -x "$HOME/.local/bin/claude" ]; then printf '%s' "$HOME/.local/bin/claude"; return; fi
  local found
  found="$(PATH="$(clean_path)" command -v claude 2>/dev/null || true)"
  printf '%s' "$found"
}
CLAUDE_BIN="$(find_claude)"

# The ref `reap` proves work against. Repos disagree on the default branch name,
# so ask the remote rather than assuming `main`.
base_ref() {
  local dir="$1" ref
  if [ -n "${TMUX_LANE_BASE_REF:-}" ]; then printf '%s' "$TMUX_LANE_BASE_REF"; return; fi
  ref="$(git -C "$dir" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  printf '%s' "${ref:-origin/main}"
}

# All lane names known to the state dir, live or dead. tmux is NOT the source of
# truth: reading tmux means a lane whose session died vanishes from the table
# entirely, and an unaccounted-for lane is exactly the one you needed to see.
all_lanes() {
  local f n
  for f in "$STATE"/*.meta; do
    [ -e "$f" ] || continue
    n="$(basename "$f" .meta)"; printf '%s\n' "$n"
  done
  # a live session with no meta (started by hand) still deserves to show up
  while read -r s; do
    case "$s" in lane-*) ;; *) continue ;; esac
    n="${s#lane-}"
    [ -f "$STATE/$n.meta" ] || printf '%s\n' "$n"
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
}

# ---------------------------------------------------------------- sampler
# The ONLY writer of .hash/.hashts. One per lane, started by `start`.
cmd_sample() {
  local name="${1:?usage: sample <name>}"
  local h prev=""
  printf '%s' "$$" > "$STATE/$name.sampler"
  while alive "$name"; do
    h="$(pane_hash "$name")"
    if [ "$h" != "$prev" ]; then
      printf '%s' "$h" > "$STATE/$name.hash"
      printf '%s' "$(date +%s)" > "$STATE/$name.hashts"
      prev="$h"
    fi
    sleep "$SAMPLE_SECS"
  done
  rm -f "$STATE/$name.sampler"
}

sampler_alive() {
  local p; p="$(cat "$STATE/$1.sampler" 2>/dev/null || true)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

start_sampler() {
  local name="$1"
  sampler_alive "$name" && return 0
  nohup "$SELF" sample "$name" >/dev/null 2>&1 &
  sleep 1
}

# ---------------------------------------------------------------- lane settings
# The fix for a worker that will not self-report. A Stop hook fires when the
# agent stops talking — deterministic, and impossible to forget. Crucially, no
# Stop event fires during a 22-minute tool call, so "quiet" and "finished" stop
# being the same observation. Lane settings MERGE with ~/.claude/settings.json,
# so the user's existing global Stop hooks are preserved, not replaced.
write_lane_settings() {
  local name="$1" f="$STATE/$name.settings.json"
  cat > "$f" <<EOF
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$SELF report --lane $name turn-ended" } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$SELF report --lane $name working" } ] }
    ]
  }
}
EOF
  printf '%s' "$f"
}

# ---------------------------------------------------------------- start
cmd_start() {
  local name="" dir="" prompt="" issue="" yolo=0 model="" send=1
  name="${1:?usage: start <name> --dir DIR --prompt TEXT [--issue N]}"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --prompt) prompt="$2"; shift 2 ;;
      --issue) issue="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --yolo) yolo=1; shift ;;
      --no-send) send=0; shift ;;
      *) die "start: unknown arg $1" ;;
    esac
  done
  command -v tmux >/dev/null 2>&1 || die "start: tmux is not installed"
  [ -n "$dir" ] || die "start: --dir is required"
  [ -d "$dir" ] || die "start: no such directory: $dir"
  [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] \
    || die "start: claude CLI not found${CLAUDE_BIN:+ at $CLAUDE_BIN}; set TMUX_LANE_CLAUDE"
  local sess; sess="$(sess_of "$name")"
  alive "$name" && die "start: session $sess already exists (never clobber a live lane)"
  [ -n "$prompt" ] || [ "$send" = 0 ] || die "start: --prompt is required (or pass --no-send)"

  # Reaped metadata is the only forensic trail a lane leaves, so it is kept — but
  # not forever, or the state dir fills with files nobody will ever read.
  find "$STATE" -name '*.meta.reaped' -mtime "+${TMUX_LANE_GC_DAYS:-14}" -delete 2>/dev/null

  local args=(--dangerously-skip-permissions)
  [ "$yolo" = 1 ] || args=()
  [ -n "$model" ] && args+=(--model "$model")
  local settings; settings="$(write_lane_settings "$name")"
  args+=(--settings "$settings")

  local branch=""
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

  # TMUX_LANE_TOOL lets the worker call `report` without knowing where this
  # script is installed — the path differs between a plugin and a manual copy.
  local env_args=(-e "PATH=$(clean_path)" -e "TMUX_LANE=$name" -e "TMUX_LANE_TOOL=$SELF")
  [ -n "${GH_HOST:-}" ] && env_args+=(-e "GH_HOST=$GH_HOST")
  [ -n "${TMUX_LANE_HOME:-}" ] && env_args+=(-e "TMUX_LANE_HOME=$TMUX_LANE_HOME")

  tmux new-session -d -s "$sess" -x 200 -y 50 -c "$dir" \
    "${env_args[@]}" \
    "$CLAUDE_BIN" "${args[@]}" || die "start: tmux new-session failed"

  # Recorded so a REPLACEMENT lead can recover after the first lead dies: lanes
  # outlive their coordinator, and without dir/issue a new lead cannot tell what
  # a lane is for without reading its pane.
  {
    printf 'name=%s\n' "$name"
    printf 'dir=%s\n' "$dir"
    printf 'issue=%s\n' "$issue"
    printf 'branch=%s\n' "$branch"
    printf 'owner=%s\n' "${TMUX_LANE_OWNER:-}"
    printf 'yolo=%s\n' "$yolo"
    printf 'started=%s\n' "$(date +%s)"
    printf 'prompt=%s\n' "$prompt"
  } > "$STATE/$name.meta"
  rm -f "$STATE/$name.hash" "$STATE/$name.hashts" "$STATE/$name.report"

  # Wait for the TUI to be ready to accept a prompt. A fresh lane can stop on a
  # startup dialog first (folder trust, a newly-seen MCP server) — report that
  # instead of timing out, because the caller has to answer it.
  local i ready=0
  for i in $(seq 1 60); do
    sleep 1
    local p; p="$(pane "$name")"
    # Dialogs first: they also draw a '❯' cursor, so readiness must not win.
    # Readiness is an *empty* input prompt line, not the footer hint — a custom
    # statusline replaces "? for shortcuts" entirely.
    #
    # Match on wording that survives rephrasing. The folder-trust dialog has been
    # reworded at least once ("Do you trust..." became "Is this a project you
    # created or one you trust?"), and a missed dialog is expensive: instead of
    # exiting 3 with the pane and instructions, `start` sits through the whole
    # 60s readiness loop and exits 4 saying nothing useful. "Enter to confirm" is
    # the select-dialog footer and catches ones not enumerated here.
    case "$p" in
      *"you trust"*|*"trust the files"*|*"trust this folder"*|*"MCP server found"*\
      |*"Enter to confirm"*|*"❯ 1."*|*"Do you want"*)
        echo "state=needs-input reason=startup-dialog  (prompt NOT sent)"
        printf '%s\n' "$p" | grep -v '^ *$' | tail -n 15
        echo "-- answer it, then send the prompt:"
        echo "   $0 key  $name Down Enter   # arrow-selected list: '❯' marks the current option"
        echo "   $0 key  $name 2            # only if the options are numbered '1.' '2.'"
        echo "   $0 poke $name '<the prompt>'"
        exit 3 ;;
    esac
    if printf '%s\n' "$p" | grep -qE '^[[:space:]]*❯[[:space:]]*$'; then ready=1; break; fi
    alive "$name" || die "start: session died during startup; last pane:
$(printf '%s' "$p" | tail -n 20)"
  done
  [ "$ready" = 1 ] || { echo "state=unknown  TUI never reported ready in 60s; peek it:"; echo "  $0 peek $name"; exit 4; }

  start_sampler "$name"
  if [ "$send" = 1 ]; then
    tmux send-keys -t "$sess" -l "$prompt"
    sleep 1
    tmux send-keys -t "$sess" Enter
  fi
  echo "started=$sess dir=$dir branch=${branch:-?} issue=${issue:-none} yolo=$yolo sent=$send"
  echo "stop-hook=on (lane reports turn-ended automatically)"
  echo "attach with: tmux attach -t $sess   (detach: Ctrl-b d)"
}

# ---------------------------------------------------------------- report
# Called by a worker, or by that worker's Stop hook. States:
#   turn-ended  the agent stopped talking (hook-driven, always trustworthy)
#   blocked     an open question or conflict — a DECISION is owed
#   done        work landed and handed off (still a claim; verify it)
#   working     explicitly still going
cmd_report() {
  local name="${TMUX_LANE:-}" st="" msg=""
  [ "${1:-}" = "--lane" ] && { name="$2"; shift 2; }
  st="${1:?usage: report [--lane NAME] <turn-ended|blocked|done|working|gate-running|landed|red> [message]}"; shift
  msg="$*"
  [ -n "$name" ] || die "report: no lane (run inside a lane, or pass --lane NAME)"
  # gate-running is the one that saves the lead the most: a lane about to spend
  # 700s in a gate says so, and `watch` stops treating it as needing attention.
  case "$st" in turn-ended|blocked|done|working|gate-running|landed|red) ;;
    *) die "report: state must be turn-ended|blocked|done|working|gate-running|landed|red" ;; esac
  # A worker's own `report blocked` must not be overwritten by the Stop hook
  # that fires immediately after it in the same turn — the question is the more
  # specific and more useful fact.
  if [ "$st" = turn-ended ] && [ -f "$STATE/$name.report" ]; then
    case "$(sed -n 's/^state=//p' "$STATE/$name.report")" in
      blocked|done|landed|red) echo "reported=$name state=kept-existing"; return 0 ;;
    esac
  fi
  { printf 'state=%s\n' "$st"; printf 'ts=%s\n' "$(date +%s)"
    printf 'msg=%s\n' "$msg"; } > "$STATE/$name.report"
  echo "reported=$name state=$st"
}

clear_report() { rm -f "$STATE/${1}.report"; }

# The sampler only looks every SAMPLE_SECS, so for up to that long after a poke
# the lane still reads `idle` — which would make `watch` fire spuriously on the
# lane we just poked. Whoever pokes stamps the activity clock.
touch_activity() { printf '%s' "$(date +%s)" > "$STATE/${1}.hashts"; }

# ---------------------------------------------------------------- classify
# Prints one line: state=<s> idle=<secs> [reason=<r>] [msg=...]
# PURE READER — writes nothing, so any number of observers can call it.
cmd_state() {
  local name="${1:?usage: state <name>}"
  if ! alive "$name"; then
    local d; d="$(meta "$name" dir)"
    echo "state=dead idle=- ${d:+dir=$d}"
    return 0
  fi
  local now pts idle
  now="$(date +%s)"
  pts="$(cat "$STATE/$name.hashts" 2>/dev/null || true)"
  if ! sampler_alive "$name"; then
    echo "state=unknown idle=- reason=sampler-dead  (restart: $0 resample $name)"
    return 0
  fi
  [ -n "$pts" ] || { echo "state=starting idle=0s reason=no-samples-yet"; return 0; }
  idle=$(( now - pts ))

  # A report is authoritative — it comes from the agent's own lifecycle, not from
  # guessing at pixels. Once `turn-ended` is set the lane really is waiting for
  # input: Stop fires when the whole response ends, and nothing resumes it but a
  # poke, which clears the report.
  #
  # A report is NEVER invalidated by pane motion. An earlier version discarded a
  # report once the pane changed more than 60s after it was written — which is
  # precisely what a healthy lane does when its own 700s gate keeps printing
  # after the turn ended. It threw the report away and fell through to
  # screen-reading, so a working lane read `idle`.
  #
  # A report is cleared by exactly one thing: the lead acting on it (poke / key /
  # answer). A worker's next turn overwrites it, and its UserPromptSubmit hook
  # sets `working` the moment it is given anything to do.
  if [ -f "$STATE/$name.report" ]; then
    local rst rmsg
    rst="$(sed -n 's/^state=//p' "$STATE/$name.report")"
    rmsg="$(sed -n 's/^msg=//p' "$STATE/$name.report")"
    echo "state=$rst idle=${idle}s reason=reported${rmsg:+ msg=$rmsg}"
    return 0
  fi

  local tail_txt; tail_txt="$(pane "$name" | tail -n 25)"
  local st reason=""
  case "$tail_txt" in
    *"Do you want"*|*"Would you like"*|*"❯ 1."*|*"1. Yes"*|*"you trust"*\
    |*"trust this folder"*|*"Enter to confirm"*)
      st=needs-input; reason=permission-prompt ;;
    *"API Error"*|*"rate limit"*|*"Overloaded"*|*"overloaded_error"*|*"Request timed out"*\
    |*"Connection error"*|*"exceed"*"limit"*)
      st=error; reason=api ;;
    *"Segmentation fault"*|*"panicked at"*|*"command not found: claude"*)
      st=error; reason=crash ;;
    *)
      if [ "$idle" -lt "$IDLE_SECS" ]; then st=working; else st=idle; fi ;;
  esac
  if { [ "$st" = needs-input ] || [ "$st" = error ]; } && [ "$idle" -lt "$SAMPLE_SECS" ]; then
    st=working; reason="${reason}-but-moving"
  fi
  echo "state=$st idle=${idle}s${reason:+ reason=$reason}"
}

cmd_resample() { start_sampler "${1:?usage: resample <name>}"; echo "sampler=restarted lane=$1"; }

# ---------------------------------------------------------------- list
cmd_list() {
  local mine=0 filter=() a
  for a in "$@"; do case "$a" in --mine) mine=1 ;; *) filter+=("$a") ;; esac; done
  local any=0 n st
  printf '%-12s %-11s %-6s %-6s %-7s %s\n' LANE STATE IDLE ISSUE AGE DIR
  while read -r n; do
    [ -n "$n" ] || continue
    if [ ${#filter[@]} -gt 0 ]; then
      local keep=0 f
      for f in "${filter[@]}"; do [ "$f" = "$n" ] && keep=1; done
      [ "$keep" = 1 ] || continue
    fi
    [ "$mine" = 1 ] && [ "$(meta "$n" owner)" != "${TMUX_LANE_OWNER:-}" ] && continue
    any=1
    local dir started age="?"
    dir="$(meta "$n" dir)"; started="$(meta "$n" started)"
    [ -n "$started" ] && age="$(( ( $(date +%s) - started ) / 60 ))m"
    st="$(cmd_state "$n")"
    printf '%-12s %-11s %-6s %-6s %-7s %s\n' "$n" \
      "$(printf '%s' "$st" | sed -n 's/.*state=\([^ ]*\).*/\1/p')" \
      "$(printf '%s' "$st" | sed -n 's/.*idle=\([^ ]*\).*/\1/p')" \
      "$(meta "$n" issue)" "$age" "${dir:-?}"
  done < <(all_lanes | sort -u)
  [ "$any" = 1 ] || echo "(no lanes)"
}

# ---------------------------------------------------------------- peek / poke
cmd_peek() {
  local name="${1:?usage: peek <name> [-n LINES]}"; shift
  local n=40; [ "${1:-}" = "-n" ] && { n="$2"; }
  alive "$name" || die "peek: no live lane $name"
  pane "$name" | grep -v '^$' | tail -n "$n"
}

cmd_poke() {
  local name="${1:?usage: poke <name> TEXT}"; shift
  alive "$name" || die "poke: no live lane $name"
  local sess; sess="$(sess_of "$name")"
  tmux send-keys -t "$sess" -l "$*"
  sleep 1
  tmux send-keys -t "$sess" Enter
  clear_report "$name"
  touch_activity "$name"
  echo "poked=$name"
}

cmd_key() {
  local name="${1:?usage: key <name> KEY...}"; shift
  alive "$name" || die "key: no live lane $name"
  tmux send-keys -t "$(sess_of "$name")" "$@"
  clear_report "$name"
  touch_activity "$name"
  echo "sent=$name keys=$*"
}

# ---------------------------------------------------------------- answer
# A lead decision delivered to a lane AND recorded on its issue, in one step.
# A keystroke into a pane leaves no audit trail; the tracker is the ledger. The
# comment goes first and a failure to record ABORTS the delivery, so a ruling
# can never exist only in one agent's scrollback.
cmd_answer() {
  local name="${1:?usage: answer <name> [--issue N] 'ruling'  [--no-issue]}"; shift
  local issue="" noissue=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue) issue="$2"; shift 2 ;;
      --no-issue) noissue=1; shift ;;
      *) break ;;
    esac
  done
  local text="$*"
  [ -n "$text" ] || die "answer: ruling text is required"
  alive "$name" || die "answer: no live lane $name"
  [ -n "$issue" ] || issue="$(meta "$name" issue)"   # default from the lane's meta
  if [ "$noissue" = 1 ]; then
    echo "WARNING: --no-issue, this ruling is NOT on the ledger"
  else
    [ -n "$issue" ] || die "answer: no issue known for lane $name; pass --issue N (or --no-issue, deliberately)"
    command -v gh >/dev/null 2>&1 \
      || die "answer: gh CLI not found; install it or pass --no-issue deliberately"
    gh issue comment "$issue" \
      --body "**Lead ruling** — delivered to lane \`$name\`

$text" >/dev/null || die "answer: gh issue comment failed; ruling NOT delivered (fix the ledger first)"
    echo "recorded=issue#$issue"
  fi
  cmd_poke "$name" "$text"
}

# ---------------------------------------------------------------- wait / watch
# Blocking watchers. Not a spin-wait on a subagent: a tmux pane has no
# notification channel. Keep --timeout under the 120s Bash ceiling for a
# foreground call, or run the call in the background and let it wake you.
# States that do NOT want the lead. `gate-running` is here on purpose: a lane
# that announced a 700s gate is healthy and must not be woken up over.
not_working() {
  case "$1" in
    *"state=working"*|*"state=starting"*|*"state=gate-running"*) return 1 ;;
    *) return 0 ;;
  esac
}

# The fingerprint watch compares against. Includes the report message, so a NEW
# blocked question fires even though the state string is still `blocked`.
fingerprint() {
  local st; st="$(cmd_state "$1")"
  printf '%s' "$(printf '%s' "$st" | sed -e 's/ idle=[0-9-]*s*//')"
}

cmd_wait() {
  local name="${1:?usage: wait <name> [--timeout S] [--idle S] [--until STATE]}"; shift
  local timeout=90 until=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      --idle) IDLE_SECS="$2"; shift 2 ;;
      --until) until="$2"; shift 2 ;;
      *) die "wait: unknown arg $1" ;;
    esac
  done
  local deadline=$(( $(date +%s) + timeout ))
  while :; do
    local st; st="$(cmd_state "$name")"
    if [ -n "$until" ]; then
      case "$st" in *"state=$until"*) echo "$st"; return 0 ;; esac
    elif not_working "$st"; then
      echo "$st"; return 0
    fi
    # Timeout is "no news", not a failure — exit 0 so a backgrounded call does
    # not surface as an error to the caller.
    [ "$(date +%s)" -ge "$deadline" ] && { echo "$st timeout=${timeout}s"; return 0; }
    sleep 3
  done
}

# The lead's loop. `watch alpha beta` scopes to named lanes; unscoped, it reports
# on every lane on the machine, including another session's.
cmd_watch() {
  local timeout=90 mine=0 lanes=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      --idle) IDLE_SECS="$2"; shift 2 ;;
      --mine) mine=1; shift ;;
      -*) die "watch: unknown arg $1" ;;
      *) lanes+=("$1"); shift ;;
    esac
  done
  local deadline=$(( $(date +%s) + timeout )) n hit scope=()
  if [ ${#lanes[@]} -gt 0 ]; then
    # A name that is neither a live session nor a known lane is a typo, not a
    # lane needing attention — otherwise it reports as `dead` forever.
    for n in "${lanes[@]}"; do
      if alive "$n" || [ -f "$STATE/$n.meta" ]; then scope+=("$n")
      else echo "watch: no such lane '$n' (ignored)" >&2; fi
    done
  else while read -r n; do
         [ -n "$n" ] || continue
         [ "$mine" = 1 ] && [ "$(meta "$n" owner)" != "${TMUX_LANE_OWNER:-}" ] && continue
         scope+=("$n")
       done < <(all_lanes | sort -u); fi
  [ ${#scope[@]} -gt 0 ] || { echo "attention=none reason=no-lanes-exist"; return 3; }

  # watch used to fire on STATE, with no memory of what it had already reported.
  # A lane parked in `turn-ended` then made every single re-arm return instantly,
  # forever, which makes multi-lane watching useless.
  #
  # It now baselines every lane at start and fires only on a CHANGE from that
  # baseline. Re-arming re-baselines, so an already-seen `turn-ended` is quiet,
  # while anything new still wakes the lead immediately.
  local -a base=()
  for n in "${scope[@]}"; do base+=("$(fingerprint "$n")"); done
  echo "watching=${scope[*]}"
  local i
  for i in "${!scope[@]}"; do
    printf '  baseline %s = %s\n' "${scope[$i]}" "${base[$i]}"
    # A lane already needing attention at baseline is quiet from here on. Say so
    # out loud, or a re-arm silently buries an unanswered question.
    not_working "${base[$i]}" && printf '    ^ ALREADY needs attention; baselined, so it will NOT re-fire. Handle it NOW.\n'
  done

  while :; do
    hit=""
    for i in "${!scope[@]}"; do
      local fp; fp="$(fingerprint "${scope[$i]}")"
      [ "$fp" != "${base[$i]}" ] && hit="${hit:+$hit }${scope[$i]}"
    done
    if [ -n "$hit" ]; then echo "attention=$hit reason=changed"; cmd_list "${scope[@]}"; return 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # A timeout is the GOOD outcome: nothing needed you. Exit 0 so a
      # backgrounded call does not render as "command failed with exit code 2".
      echo "attention=none timeout=${timeout}s reason=no-change"
      return 0
    fi
    sleep 3
  done
}

# No `ack` subcommand: re-arming watch re-baselines, which IS the acknowledgement.
# A separate ack file would be a second source of truth for the same fact.

# ---------------------------------------------------------------- reap
# The bar is "nothing unmerged into the base ref", NOT "level with the lane's own
# upstream". Comparing to a stale upstream refuses a clean, fully-merged
# worktree, and a false refusal is worse than none because it pushes the operator
# onto --force.
cmd_reap() {
  local name="${1:?usage: reap <name> [--force]}"; shift
  local force=0; [ "${1:-}" = "--force" ] && force=1
  local dir; dir="$(meta "$name" dir)"
  if [ "$force" = 0 ] && [ -n "$dir" ] && [ -d "$dir" ]; then
    local dirty unmerged base
    dirty="$(git -C "$dir" status --porcelain 2>/dev/null | head -n 20)"
    if [ -n "$dirty" ]; then
      echo "REFUSED: uncommitted work in $dir"; printf '%s\n' "$dirty"; return 1
    fi
    base="$(base_ref "$dir")"
    git -C "$dir" fetch "${base%%/*}" "${base#*/}" -q 2>/dev/null || true
    if ! git -C "$dir" rev-parse --verify -q "$base" >/dev/null; then
      echo "REFUSED: cannot resolve $base in $dir — cannot prove the work is landed"; return 1
    fi
    unmerged="$(git -C "$dir" rev-list --count "$base..HEAD" 2>/dev/null || echo unknown)"
    if [ "$unmerged" != 0 ]; then
      echo "REFUSED: $unmerged commit(s) in $dir not merged into $base:"
      git -C "$dir" log --oneline "$base..HEAD" 2>/dev/null | head -n 10
      return 1
    fi
  fi
  local p; p="$(cat "$STATE/$name.sampler" 2>/dev/null || true)"
  [ -n "$p" ] && kill "$p" 2>/dev/null
  alive "$name" && tmux kill-session -t "$(sess_of "$name")"
  rm -f "$STATE/$name.hash" "$STATE/$name.hashts" "$STATE/$name.report" \
        "$STATE/$name.sampler" "$STATE/$name.settings.json"
  mv -f "$STATE/$name.meta" "$STATE/$name.meta.reaped" 2>/dev/null
  echo "reaped=$name force=$force"
}

cmd_attach() { echo "tmux attach -t $(sess_of "${1:?}")   # detach: Ctrl-b d"; }

sub="${1:-}"; shift 2>/dev/null || true
case "$sub" in
  start) cmd_start "$@" ;;
  report) cmd_report "$@" ;;
  answer) cmd_answer "$@" ;;
  list|ls) cmd_list "$@" ;;
  peek) cmd_peek "$@" ;;
  state) cmd_state "$@" ;;
  poke) cmd_poke "$@" ;;
  key) cmd_key "$@" ;;
  wait) cmd_wait "$@" ;;
  watch) cmd_watch "$@" ;;
  reap) cmd_reap "$@" ;;
  attach) cmd_attach "$@" ;;
  sample) cmd_sample "$@" ;;
  resample) cmd_resample "$@" ;;
  *) sed -n '2,50p' "$0"; exit 1 ;;
esac
