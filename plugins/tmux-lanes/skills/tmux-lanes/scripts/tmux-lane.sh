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
#   reap   <name> [--force] [--rm-worktree]
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

# Put TEXT into a lane's input without submitting it.
#
# send-keys -l types literally, so an embedded newline is an Enter press: a
# multi-line message would be submitted one line at a time and the worker would
# act on the first fragment before it had seen the rest. Multi-line therefore
# goes through tmux's paste buffer in BRACKETED PASTE mode (-p), which lands the
# whole text in one input exactly as a human pasting it.
#
# Shared by `start --prompt` and `poke` so they cannot drift: fixing only one of
# them leaves the same bug on the other path.
deliver_text() {
  local sess="$1" name="$2" text="$3"
  case "$text" in
    *"
"*)
      printf '%s' "$text" | tmux load-buffer -b "tmux-lane-$name" - \
        || die "deliver: could not load the paste buffer"
      tmux paste-buffer -d -p -b "tmux-lane-$name" -t "$sess" \
        || die "deliver: could not paste into $sess" ;;
    *)
      tmux send-keys -t "$sess" -l "$text" ;;
  esac
}
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

# Same capture, but keeping the SGR escapes. Needed because Claude Code draws a
# rotating suggestion hint on the input line ("❯ Try \"how does X work?\"") in
# DIM (SGR 2). Stripped of escapes that is indistinguishable from text a human
# typed, so anything that must tell "empty input" from "queued input" has to
# look at the styling, not the characters.
pane_esc() { tmux capture-pane -p -e -J -t "$(sess_of "$1")" 2>/dev/null; }

# Strip SGR sequences. Used to compare pane text without styling.
strip_sgr() {
  # CSI ...m (colour/attributes) AND OSC 8 hyperlinks, the latter terminated by
  # either BEL or ESC-backslash. tmux `capture-pane -e` emits OSC 8 and Claude
  # Code uses it for its session link, so without this `peek` prints raw
  # "]8;id=...;https://..." fragments into the lead's view. sed -E throughout:
  # in BRE the alternation below is literal text, which silently strips nothing.
  sed -E -e $'s/\x1b\\[[0-9;]*m//g' \
         -e $'s/\x1b\\]8;[^\x07\x1b]*(\x07|\x1b\\\\)//g'
}

# True when the pane text on stdin shows a modal dialog. Always tested on
# STRIPPED text: a footer whose key names are emphasised renders as
# "\e[1mEnter\e[22m to confirm", which no raw-text match would catch.
has_dialog() {
  # Materialised, not `grep -q`: under `set -o pipefail` a -q exits on first
  # match and can SIGPIPE strip_sgr, so a SUCCESSFUL match reports failure.
  local hit; hit="$(strip_sgr | grep -E 'Enter to confirm|Esc to cancel' | head -n1)"
  [ -n "$hit" ]
}

# True when the TUI is ready to accept a prompt.
#
# This used to require a literally empty '❯' line. Claude Code v2.1.252 renders
# the suggestion placeholder there, so the line is never empty, `start` burned
# the full 60s readiness loop, exited 4 WITHOUT sending the prompt and WITHOUT
# starting the sampler — the lane came up idle and invisible. Readiness is now
# "the input line holds nothing the operator typed": either genuinely empty, or
# carrying only dim-styled placeholder text.
# Split from tui_ready so the classification can be tested against recorded
# `capture-pane -e` fixtures without a live tmux session. The bug this replaced
# was a regex that silently stopped matching after an upstream TUI change, and
# nothing in CI exercised it — text-in keeps that class of breakage testable.
tui_ready_text() {
  local pe; pe="$(cat)"
  [ -n "$pe" ] || return 1

  # Results are materialised into variables rather than tested with `grep -q` at
  # the end of a pipe. Under `set -o pipefail`, `grep -q` exits on first match and
  # can SIGPIPE its upstream (141), making a SUCCESSFUL match report failure — the
  # lane would read not-ready for no visible reason.
  local hit

  # A pane showing a dialog is never ready, whatever the input line looks like.
  # The numbered-row exclusion below does not cover the folder-trust dialog,
  # which is arrow-selected and UNNUMBERED: a dim-styled selected row there would
  # otherwise read as ready and `start` would fire its prompt into the dialog.
  printf '%s\n' "$pe" | has_dialog && return 1

  # Genuinely empty input line.
  hit="$(printf '%s\n' "$pe" | strip_sgr | sed -e 's/[[:space:]]*$//' \
         | grep -E '^[[:space:]]*❯[[:space:]]*$' | head -n1)"
  [ -n "$hit" ] && return 0

  # Input line whose content begins with a dim run — the placeholder hint.
  #
  # The anchor allows a leading run of SGR escapes: a real capture renders the
  # line as "\e[39m❯ \e[2mTry ...", so '❯' is NOT the first byte, and an anchor
  # of '^[[:space:]]*❯' looks right while matching nothing.
  #
  # Extended-colour introducers are excluded FIRST. "\e[38;2;R;G;Bm" (24-bit) and
  # "\e[38;5;2m" (256-colour) contain a 2 as a SUB-parameter, so a naive "2
  # anywhere" test reads real operator-typed text drawn in truecolour as a dim
  # placeholder — reporting ready, and masking a queued instruction in `peek`.
  # That is the precise harm this whole change exists to prevent.
  local anchor='^([[:space:]]|'$'\x1b''\[[0-9;]*m)*❯[[:space:]]*'
  local dim="${anchor}"$'\x1b''\[([0-9;]*;)?2(;[0-9;]*)?m'
  local ext="${anchor}"$'\x1b''\[[34]8;'
  hit="$(printf '%s\n' "$pe" | grep -E "$dim" | grep -vE "$ext" \
         | grep -vE "${dim}[0-9]+\." | head -n1)"
  [ -n "$hit" ] && return 0
  return 1
}

tui_ready() { pane_esc "$1" | tui_ready_text; }

# Render pane text for human reading. Split out for the same reason as above.
peek_render() {
  # Same anchor caveat as tui_ready_text: SGR escapes precede the '❯'.
  #
  # A pane showing a dialog is never masked at all. '❯' is also the selection
  # marker, and the folder-trust dialog — the one `start` enumerates — is
  # arrow-selected and UNNUMBERED, so the numbered-row exclusion below does not
  # cover it. If a selected row were ever drawn dim, masking it would hide which
  # option is highlighted while asserting the input is empty, and the lead would
  # key blind: a worse failure than the placeholder confusion being fixed. When a
  # dialog footer is on screen the lead needs the pane verbatim, so pass it through.
  local buf; buf="$(cat)"
  if printf '%s\n' "$buf" | has_dialog; then
    printf '%s\n' "$buf" | strip_sgr | sed -e 's/[[:space:]]*$//'
    return 0
  fi
  printf '%s\n' "$buf" \
    | sed -E $'/^(([[:space:]]|\x1b\\[[0-9;]*m)*❯[[:space:]]*)\x1b\\[[34]8;/b
/^(([[:space:]]|\x1b\\[[0-9;]*m)*❯[[:space:]]*)\x1b\\[([0-9;]*;)?2(;[0-9;]*)?m[0-9]+\\./b
s/^(([[:space:]]|\x1b\\[[0-9;]*m)*❯[[:space:]]*)\x1b\\[([0-9;]*;)?2(;[0-9;]*)?m.*$/\\1(empty — dim placeholder hint hidden)/' \
    | strip_sgr | sed -e 's/[[:space:]]*$//'
}

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
  # .sampler too: start_sampler short-circuits on a live PID in that file, and a
  # sampler killed with -9 or lost to a reboot leaves the PID behind. If it has
  # been recycled onto an unrelated process the new lane never gets a sampler.
  rm -f "$STATE/$name.hash" "$STATE/$name.hashts" "$STATE/$name.report" "$STATE/$name.sampler"

  # The sampler starts BEFORE the readiness wait, not after it. Every failure
  # path below (startup dialog, readiness timeout) leaves a live tmux session
  # behind, and a session with no sampler reads `unknown reason=sampler-dead`
  # forever — the lane is running and completely unobservable. Starting it here
  # costs one background process on paths that used to abandon the lane.
  start_sampler "$name"

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
    if tui_ready "$name"; then ready=1; break; fi
    alive "$name" || die "start: session died during startup; last pane:
$(printf '%s' "$p" | tail -n 20)"
  done
  if [ "$ready" != 1 ]; then
    echo "state=unknown  TUI never reported ready in 60s (sampler IS running; prompt NOT sent):"
    echo "  $0 peek $name"
    echo "  $0 poke $name '<the prompt>'   # send it by hand once the pane looks ready"
    exit 4
  fi

  if [ "$send" = 1 ]; then
    deliver_text "$sess" "$name" "$prompt"
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
  # Render the input line honestly. Claude Code draws a dim suggestion hint after
  # '❯'; with the escapes stripped it reads exactly like queued input, and a lead
  # scanning panes will believe someone typed an instruction into the lane. Mark
  # a dim-styled input line explicitly before flattening the rest of the pane.
  # See peek_render: a pane showing a dialog is passed through verbatim, and
  # numbered rows are skipped, so a selected option is never masked away.
  pane_esc "$name" | peek_render | grep -v '^$' | tail -n "$n"
}

cmd_poke() {
  local name="${1:?usage: poke <name> TEXT}"; shift
  alive "$name" || die "poke: no live lane $name"
  local sess; sess="$(sess_of "$name")"
  local text="$*"
  deliver_text "$sess" "$name" "$text"
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
  local name="${1:?usage: reap <name> [--force] [--rm-worktree]}"; shift
  local force=0 rm_wt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      --rm-worktree) rm_wt=1 ;;
      *) die "reap: unknown option $1" ;;
    esac
    shift
  done
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
      # Ancestry alone is the wrong test in a squash-merge or rebase-merge repo:
      # the content lands under a NEW commit, so the lane's own commits are never
      # ancestors of the base and this check refuses FOREVER — which trains the
      # operator to reach for --force, the button that destroys work. That is the
      # same false-refusal failure the base-ref choice was made to avoid.
      #
      # `unmerged` can be the literal string "unknown" when rev-list itself
      # failed, and that string is != 0, so it reaches here. Empty `git diff`
      # output does NOT mean "trees match" — a failed diff is also empty, with
      # stderr discarded. Both must stay on the refusal side, or the
      # undeterminable case reaps with a reassuring "landed" note, which is
      # exactly the rule this tool refuses to break: undeterminable is a
      # refusal, not a pass.
      # Compare only the paths this lane touched, not the whole tree. A whole-tree
      # `diff $base..HEAD` is empty only while the base ref sits exactly where the
      # lane's merge left it — the moment ANOTHER lane lands, the diff fills with
      # that lane's changes in reverse and this refuses again. With parallel lanes
      # that is the normal case, so a whole-tree compare would reinstate the
      # refuse-forever bug it was added to fix.
      local mb="" treediff="" landed=0 names="" namesok=0
      local -a lp=()
      mb="$(git -C "$dir" merge-base "$base" HEAD 2>/dev/null || true)"
      if [ "$unmerged" != unknown ] && [ -n "$mb" ]; then
        # NUL-delimited, with quoting OFF and every pathspec marked literal.
        # By default git C-quotes any path holding non-ASCII bytes — "caf\303\251.md"
        # — and that 15-byte string fed back as a pathspec matches NOTHING, so the
        # diff returns empty and empty is read as "landed". A lane whose only
        # unlanded change sat in such a file would be reaped: a silent false pass
        # on the one gate this command exists to hold. :(literal) likewise stops a
        # name containing *, ?, [ or a leading : being taken as pathspec magic.
        #
        # The exit status is captured rather than dropped into a pipeline: a FAILED
        # --name-only also yields no paths, and "the command broke" must not be
        # indistinguishable from "the lane changed nothing".
        # Via a temp FILE, not a command substitution: `$(...)` silently strips
        # NUL bytes, so capturing -z output that way concatenates every path into
        # one meaningless string that matches nothing — and "matches nothing"
        # reads as landed here. That false-passes every divergent lane, which is
        # strictly worse than the quoting bug this call exists to fix. A file
        # preserves the NULs and still lets the exit status be checked.
        names="$(mktemp)" || die "reap: could not create a temp file"
        if git -C "$dir" -c core.quotePath=false diff --name-only -z "$mb" HEAD \
             > "$names" 2>/dev/null; then
          namesok=1
          while IFS= read -r -d '' pth; do
            [ -n "$pth" ] && lp+=(":(literal)$pth")
          done < "$names"
        fi
        rm -f "$names"
      fi
      if [ "$namesok" = 1 ]; then
        if [ ${#lp[@]} -eq 0 ]; then
          landed=1   # the lane changed no files at all
        elif treediff="$(git -C "$dir" diff "$base" HEAD -- "${lp[@]}" 2>/dev/null)" \
             && [ -z "$treediff" ]; then
          landed=1
        fi
      fi
      if [ "$landed" = 1 ]; then
        echo "note: $unmerged commit(s) are not ancestors of $base, but every path"
        echo "      this lane touched matches it — landed via squash or rebase merge."
      elif [ "$unmerged" = unknown ] || [ -z "$mb" ] || [ "$namesok" != 1 ]; then
        echo "REFUSED: cannot compare $dir against $base — undeterminable is a"
        echo "         refusal, not a pass. Check the worktree by hand."
        return 1
      else
        echo "REFUSED: $unmerged commit(s) in $dir not merged into $base,"
        echo "         and paths this lane touched still differ from it:"
        git -C "$dir" log --oneline "$base..HEAD" 2>/dev/null | head -n 10
        return 1
      fi
    fi
  fi
  local p; p="$(cat "$STATE/$name.sampler" 2>/dev/null || true)"
  [ -n "$p" ] && kill "$p" 2>/dev/null
  alive "$name" && tmux kill-session -t "$(sess_of "$name")"
  # .sampler too: start_sampler short-circuits on a live PID in that file, and a
  # sampler killed with -9 or lost to a reboot leaves the PID behind. If it has
  # been recycled onto an unrelated process the new lane never gets a sampler.
  rm -f "$STATE/$name.hash" "$STATE/$name.hashts" "$STATE/$name.report" "$STATE/$name.sampler" \
        "$STATE/$name.sampler" "$STATE/$name.settings.json"
  mv -f "$STATE/$name.meta" "$STATE/$name.meta.reaped" 2>/dev/null
  echo "reaped=$name force=$force"

  # Reaping ends the SESSION; the worktree is a separate resource and it is the
  # expensive one — a per-lane node_modules is hundreds of MB, and an unattended
  # run that reaps ten lanes reclaims none of it unless asked. Say so every time,
  # so a leftover worktree is never silent.
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    if [ "$rm_wt" = 1 ]; then
      # `worktree list --porcelain` names the MAIN worktree on its first line, in
      # every layout. Deriving it by stripping "/.git" off the common git dir
      # breaks on --separate-git-dir, bare and .bare clones, and needs git 2.31.
      local top; top="$(git -C "$dir" worktree list --porcelain 2>/dev/null \
                        | sed -n '1s/^worktree //p')"
      # Plain remove when the guards above actually ran: they already proved the
      # tree is clean and landed, so --force buys nothing and only removes git's
      # own last check. Under `reap --force` those guards were SKIPPED, so the
      # tree may hold uncommitted work — git's refusal is then the only thing
      # standing between the operator and silent data loss, and it is honoured
      # unless they forced deliberately.
      local rmargs=(worktree remove); [ "$force" = 1 ] && rmargs=(worktree remove --force)
      local err=""
      if [ -z "$top" ] || [ ! -d "$top" ]; then
        # Distinct from a git refusal: --path-format=absolute needs git >= 2.31,
        # and a generic FAILED with no reason is the kind of line operators skim.
        echo "worktree-remove-FAILED=$dir"
        echo "  could not locate the main repo for it; remove it by hand"
        printf 'worktree_left=%s\n' "$dir" >> "$STATE/$name.meta.reaped" 2>/dev/null
      elif err="$(git -C "$top" "${rmargs[@]}" "$dir" 2>&1)"; then
        git -C "$top" worktree prune 2>/dev/null
        echo "worktree-removed=$dir"
      else
        echo "worktree-remove-FAILED=$dir"
        printf 'worktree_left=%s\n' "$dir" >> "$STATE/$name.meta.reaped" 2>/dev/null
        [ -n "$err" ] && printf '  %s\n' "$err" | head -n 5
        echo "  (remove it by hand, or re-run with --force if you meant to discard it)"
      fi
    else
      echo "worktree-left=$dir  (pass --rm-worktree to reclaim it)"
      # The lane is gone from `list` by now, so stdout would be the only record.
      printf 'worktree_left=%s\n' "$dir" >> "$STATE/$name.meta.reaped" 2>/dev/null
    fi
  fi
}

cmd_attach() { echo "tmux attach -t $(sess_of "${1:?}")   # detach: Ctrl-b d"; }

# Only dispatch when executed, not when sourced. Sourcing is how the parsing
# functions get tested without a live tmux session; without this guard a source
# falls straight through to the '*)' catch-all, prints usage and exits 1.
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then return 0 2>/dev/null || true; fi

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
