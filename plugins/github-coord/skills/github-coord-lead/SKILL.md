---
name: github-coord-lead
description: Act as the orchestrator answering implementation agents through GitHub issue comments and coord:* labels. Use this when you are running an epic across child issues, worktrees, or subagents and need to sweep for waiting workers, triage which blocker to answer first, resolve a worker's question or decision request from the spec and plan, dispose of a proposed follow-up issue, clear coordination labels safely, or produce an epic reconciliation report. Also use it when asked to "check on the agents", "see if anything is blocked", "answer the workers", "unblock the epic", "any open agent requests?", or before declaring an epic complete. Reach for it whenever you own tracker metadata that workers are forbidden to change.
---

# Lead-side GitHub coordination

You are the orchestrator. Workers can only add three labels and post comments;
every removal, milestone change, assignment, dependency edit, and issue-state
transition is yours. That asymmetry is deliberate — it means the coordination
labels tell you the truth about who is waiting, but only if you are the one who
clears them, and only after you've actually answered.

Announce: "Using github-coord-lead to sweep and resolve agent requests on <epic>."

Your workers should be running `github-coord-worker`, the other half of this
protocol. If they aren't, they won't emit the markers this skill pairs on — say so
when you dispatch them, or expect to read every thread by hand.

Two failure modes to design against. The first is a worker blocked for an hour on
something you could have answered in thirty seconds — that's what the sweep is
for. The second is clearing a semaphore while a second request is still open,
which strands a worker with no signal left to raise; that's what the re-fetch
before clearing is for.

## The helper script

Three jobs are too error-prone to do by hand, so `scripts/coord.py` (Python 3,
stdlib only, shells out to `gh`) does them: `threads` pairs requests to responses
on one issue, `sweep` finds and ranks signaled issues, `reconcile` clears labels
only when it's safe. Everything else in this skill is plain `gh`.

Resolve its path once per session. The script sits beside this file, so set
`COORD` to `<the directory you loaded this SKILL.md from>/scripts/coord.py` —
you already know that path. Depending on how this is installed it's one of:

```sh
COORD="$CLAUDE_PLUGIN_ROOT/skills/github-coord-lead/scripts/coord.py"  # Claude Code plugin
COORD=~/.claude/skills/github-coord-lead/scripts/coord.py              # manual, Claude Code
COORD=~/.codex/skills/github-coord-lead/scripts/coord.py               # manual, Codex

python3 "$COORD" --help   # confirm it resolves before you rely on it
```

If it won't resolve, don't stall on it: `gh issue list --search 'state:open
label:"coord:needs-attention"'` gets you the same sweep, and you read the threads
yourself. The script saves tokens and catches the clear-too-early race — it isn't
load-bearing for the protocol.

## The signals you're reading

Level-triggered, not event-triggered — each label asserts a condition that is
true *right now*:

| Label | Means | You clear it when |
|---|---|---|
| `coord:needs-attention` | ≥1 unresolved request here | *Every* open request has a response |
| `coord:blocked` | Cannot make dependency-safe progress | Your response genuinely permits progress |
| `coord:follow-up-proposed` | A follow-up awaits disposition | You've recorded an explicit disposition |

One-time setup per repo — workers can only add a label that exists, so define all
three before dispatching anyone:

```sh
R=owner/name
gh label create "coord:needs-attention" --repo $R --color D93F0B \
  --description "Unresolved agent request awaiting the orchestrator" 2>/dev/null || true
gh label create "coord:blocked" --repo $R --color B60205 \
  --description "Issue cannot make dependency-safe progress" 2>/dev/null || true
gh label create "coord:follow-up-proposed" --repo $R --color 0E8A16 \
  --description "Proposed follow-up issue awaiting disposition" 2>/dev/null || true
```

## Sweep

During active epic execution, poll rather than assume. The underlying query is
`state:open label:"coord:needs-attention"`; scope it to your epic by milestone,
by the epic's issue references, or by parent relationship where supported.

```sh
python3 "$COORD" sweep --repo owner/name --milestone "Wave 2" --deep
# or: --epic 38   (matches issues referencing #38)
# --deep also reads each issue's comments and names the unanswered request IDs
```

`--deep` costs extra API calls and earns them: it distinguishes an issue with a
genuinely open request from one whose label is merely stale, and it tells you the
request types before you read a single comment. Without it you're guessing which
issue to open first.

Sweep on a real cadence — after each worker dispatch, at each wave boundary, and
before any reconciliation report. A sweep you skip is a worker still waiting.

## Triage order

When several issues are signaled, answer in this order, because the cost of delay
differs by an order of magnitude between the top and bottom of this list:

1. `coord:blocked` — an agent is doing nothing at all.
2. Decisions spanning multiple issues or waves — delay here multiplies into
   rework across every issue downstream.
3. Acceptance-criteria or security concerns — cheapest to fix before merge.
4. Follow-up proposals — the worker is still productive, but scope is drifting
   until you rule.
5. Non-blocking questions.

Within a tier, oldest `updatedAt` first. A worker that has waited twice as long
has usually burned twice as much of its context on waiting.

## Resolving one issue

For every signaled issue:

1. **Read the whole context** — the issue, its parent epic, its dependencies, and
   all comments. Answering from the issue title alone is how contradictory
   decisions get issued to two workers.
2. **Enumerate the open requests.** `coord.py threads --repo owner/name --issue N`
   pairs each request marker with any later response and prints which IDs are
   still open. Later matters: a response that predates a request doesn't answer
   it.
3. **Resolve from authority, not from taste.** In order: approved specification,
   the epic plan, the issue contract, then repository state. Your job is to be
   consistent with what was already agreed, not to redesign it. Cite which source
   decided it — a worker that knows the basis can resolve the next similar
   question itself.
4. **Escalate to the human owner only when the sources genuinely cannot decide** —
   the spec is silent or self-contradictory, the choice changes agreed scope,
   cost, or security posture, or it's irreversible. Use disposition
   `owner-input-required`, say precisely what you need decided, and leave
   `coord:needs-attention` in place. Guessing here is worse than waiting.
5. **Post one response per request ID.** Never one comment answering three
   requests — pairing is per-ID, and a worker will read only the one matching its
   own ID. Template and worked example are in `references/response-playbook.md`;
   read it before your first response.

```sh
gh issue comment 42 --repo owner/name --body-file /tmp/resp.md
```

6. **Create and link the follow-up issue when you approve one**, then reference it
   in the response. An approved follow-up with no issue number is an approval
   nobody can act on.

## Clearing labels without stranding anyone

Re-fetch comments immediately before you clear anything. Between your read and
your write, a second worker may have added a request on the same issue — and if
you clear `coord:needs-attention` on the strength of the last comment you saw,
that request becomes invisible.

```sh
python3 "$COORD" reconcile --repo owner/name --issue 42 \
  --remove coord:needs-attention --remove coord:blocked
```

`reconcile` re-reads the thread and refuses to remove `coord:needs-attention`
while any request lacks a later response. If you must override — say a request is
withdrawn or duplicated — pass `--force` and state the reason in a comment, so
the next sweep can tell an intentional clear from a mistake. It also refuses to
touch labels outside the `coord:*` set; other label policy is separate from this
protocol.

Clear each label on its own merits:

- `coord:blocked` — only if your answer actually restores dependency-safe
  progress. "Owner input required" does not.
- `coord:follow-up-proposed` — only after an explicit disposition is recorded
  (approved with an issue number, declined with a reason, or deferred to a named
  point).

## Epic reconciliation

At each reconciliation point, report:

- unresolved request IDs, with the issue each sits on;
- blocked issues and precisely what would unblock each;
- follow-up proposals and their dispositions;
- decisions made since the last reconciliation, with their basis;
- active agents, branches, and worktrees;
- the next dependency-safe work.

Do not report an epic complete while any required issue still carries an
unresolved coordination request. "All PRs merged" and "no agent is still waiting
on an answer" are different claims, and only the second one means the epic's
decisions were actually made. Run a final `sweep --deep` scoped to the epic and
say what it returned.

## Responding to your own human

Surface what needs a person: `owner-input-required` dispositions, security and
acceptance concerns, and scope changes you approved. Keep the rest in the issue
threads. A summary that reprints every answered question buries the two that
needed a human.
