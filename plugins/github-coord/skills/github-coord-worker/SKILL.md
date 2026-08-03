---
name: github-coord-worker
description: Communicate upward from an implementation agent to its orchestrator through GitHub issue comments and coord:* labels. Use this whenever you are working an assigned GitHub issue (in a worktree, as a subagent, or as a delegated worker) and you hit something you should not decide alone — an ambiguous or conflicting acceptance criterion, a plan that contradicts the code, a missing dependency, a scope change, a security or compatibility worry, work that belongs in a separate follow-up issue, or a hard blocker. Also use it when told to "ask the lead", "report a blocker", "escalate", "flag a concern", "propose a follow-up issue", or to acknowledge a decision that came back on an issue. Reach for it before you invent an answer, silently widen scope, stall, or edit tracker metadata you do not own.
---

# Worker-side GitHub coordination

You are an implementation worker on one issue. Your orchestrator is not watching
your terminal — the issue thread is the only place a message reliably lands. So a
question you keep in your head is a question nobody answered, and a guess you make
quietly becomes a defect somebody discovers three issues later.

Announce: "Using github-coord-worker to raise <type> on #<issue>."

Two habits make this work: post requests where the decision actually belongs, and
keep working on everything the unanswered question does not touch.

The orchestrator side of this protocol is `github-coord-lead`. You don't need it
loaded, but it's worth knowing what's on the other end: a lead that sweeps for the
labels you add and pairs its answer to your request ID.

## Establish context first

You cannot write a useful request without these. Gather them before posting:

- repository (`OWNER/NAME`);
- active issue number and its acceptance criteria;
- parent epic number, if any;
- your agent identity (a stable name the lead can address, e.g. `claude-worker-2`);
- branch name and absolute worktree path;
- milestone and upstream dependencies.

Read the repo's `AGENTS.md` / `CLAUDE.md` if present — it may add ownership,
dependency, or branch records you must have on file before touching code, and it
overrides anything here.

Get the tracking record straight before implementing. A request that says
"blocked on #41" is actionable; "something about a dependency" costs the lead a
round trip.

## What you decide vs. what you escalate

The point of escalating is to protect decisions that are expensive to reverse or
that reach past your issue. Everything else is your job.

Decide yourself, and note the choice in your work summary:

- reversible, in-scope implementation choices where the requirements already
  imply one answer (helper naming, test layout, local refactors);
- anything you could change later without touching another issue's contract.

Escalate:

- semantic ambiguity in the spec or plan;
- acceptance criteria that conflict with each other or with the code;
- an assumption you would have to make that could be wrong and unsafe;
- a dependency or wave-ordering error in the plan;
- scope changes, including scope you'd have to grow into to finish;
- genuinely out-of-scope findings that deserve their own issue;
- security, data-loss, or compatibility implications.

A blocker is not a way to hand an ordinary implementation choice to someone else.
Overusing it trains the lead to skim your requests, which costs you the one time
it really matters.

## Where to post

Post on **your issue** when the request concerns its implementation, tests,
acceptance criteria, files, or local design.

Post on the **parent epic** when the answer would change cross-issue scope,
dependency or wave ordering, plan semantics, integration behavior, shared file
ownership, final acceptance, or whether a follow-up belongs in the epic.

For something cross-cutting you discovered while working your issue:

1. Post the full evidence on your issue.
2. Post a short epic comment that links to that child comment and states the
   decision needed.
3. Apply the coordination label to the **epic** — that's where the lead must act.

Don't paste the whole discussion twice; a lead reading two copies can't tell
which one is current.

## Labels are semaphores, not messages

Three labels, and they are level-triggered — each means "this condition is true
right now", not "this event happened":

| Label | Meaning |
|---|---|
| `coord:needs-attention` | At least one unresolved request exists here. |
| `coord:blocked` | This issue cannot make dependency-safe progress. |
| `coord:follow-up-proposed` | A proposed follow-up issue awaits disposition. |

You may **add** those three labels and nothing else. Do not remove any label, and
do not touch milestones, assignees, dependencies, issue state, or other tracker
metadata — the orchestrator owns those, and a worker clearing its own signal is
how a request gets silently lost. Never invent labels like `coord:answered` or
`coord:question-3`; answers and acknowledgements live in comments, and per-question
labels turn the label list into an unreadable log.

If repo policy doesn't let you add labels either, post the request comment anyway
and say in it that labels need applying. The comment is the durable part.

## Posting a request

One request ID per distinct question, formatted
`REQ-<issue>-<UTC timestamp>-<agent-name>`:

```sh
REQ="REQ-42-$(date -u +%Y%m%dT%H%M%SZ)-claude-worker-2"
# REQ-42-20260803T171204Z-claude-worker-2
```

Read `references/request-template.md` now if you have not already — it carries
the exact marker syntax and a worked example. Write the filled body to a file,
then post and signal:

```sh
gh issue comment 42 --repo owner/name --body-file /tmp/req.md
gh issue edit 42 --repo owner/name --add-label "coord:needs-attention"
# also --add-label "coord:blocked" when no dependency-safe work remains
# also --add-label "coord:follow-up-proposed" when the request proposes a new issue
```

Post the comment before the label. The label is a pointer; a pointer to nothing
sends the lead looking for a request that isn't there yet.

Check your comment actually carries the `<!-- agent-coordination:request ... -->`
marker with your request ID before you consider it published. The lead's tooling
pairs requests to responses by that marker, so a comment without one is invisible
to the sweep no matter how well written it is.

If the labels don't exist in the repo yet, create them once — a lead sweeping for
a label that was never defined finds nothing:

```sh
gh label create "coord:needs-attention" --repo owner/name \
  --color D93F0B --description "Unresolved agent request awaiting the orchestrator" 2>/dev/null || true
```

Write the request so it can be answered in one reply. Concretely: one precise
question, real evidence (command output, file:line, the conflicting plan text),
the options you already considered with tradeoffs, your recommendation and why,
what stalls if nobody answers, and what you're continuing on meanwhile. A lead
who can approve your recommendation costs one comment; a vague question costs
three.

## While you wait

Publish first, then wait — never the reverse. Silently waiting on a request you
never posted is indistinguishable from a hung agent.

If dependency-safe work remains: keep going on it, and leave the code paths the
pending decision would affect untouched. Say in the request which work continues,
so the lead knows what they'd be invalidating.

If you're fully blocked:

1. Confirm the request and labels actually published. `scripts/coord.py` sits
   beside this file — set `COORD` to `<the directory you loaded this SKILL.md
   from>/scripts/coord.py`, which is
   `$CLAUDE_PLUGIN_ROOT/skills/github-coord-worker/scripts/coord.py` when
   installed as a Claude Code plugin, or
   `~/.claude/skills/github-coord-worker/scripts/coord.py` (or the `~/.codex`
   equivalent) for a manual install:

   ```sh
   python3 "$COORD" threads --repo owner/name --issue 42
   ```

   It lists every request ID on the issue and whether anything answered it —
   order-aware, so an older comment can't make your new request look answered. If
   the script isn't there, `gh issue view 42 --repo owner/name --json comments`
   and look for your marker; the check matters, the tool doesn't.
2. Poll with whatever native wait or monitoring mechanism your runtime offers.
   Don't hold a long shell `sleep` when a real wait primitive exists — a sleeping
   shell burns the session's wall clock and can outlive its usefulness.
3. Read only responses matching your request ID; another worker's answer on the
   same issue is not yours.
4. If your session can't stay alive, stop cleanly and report the issue URL and
   request ID so a later session or the human can pick it up. Ending with those
   two facts is a successful handoff; ending with "I was blocked" is not.

## Proposing a follow-up issue

You propose; you do not create or close the follow-up unless you are explicitly
acting as the orchestrator. Leads need scope control more than they need one
fewer issue to file.

A proposal earns a fast yes when it answers: why the work sits outside this
issue, whether it blocks current acceptance, the exact proposed scope, affected
files or components, dependencies, suggested acceptance criteria, verification
expectations, and any security or compatibility implications.

Non-blocking proposal → say so and carry on with the current issue.

## Acknowledging a response

When a response lands, close the loop with an ack (template in
`references/request-template.md`, `ack` section):

```sh
gh issue comment 42 --repo owner/name --body-file /tmp/ack.md
```

State what you'll do next, whether you resumed or are still blocked, and any
remaining concern. The ack is what lets the lead trust the semaphore reflects
reality rather than an answer that missed the point.

If the response doesn't actually unblock you, don't reuse the old ID — mint a new
request ID, explain specifically what's still undecided, and re-add
`coord:needs-attention`. Reusing an ID makes the thread unreadable and the lead's
pairing logic will treat you as already answered.

## Reporting back to your own caller

When you finish or stop, include in your summary: the issue and branch, requests
you raised and their state, decisions you made yourself, and follow-ups you
proposed. Your caller may be another agent that has to reconcile the epic, and it
can only report what you tell it.
