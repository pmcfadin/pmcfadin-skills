# github-coord

Two skills that let a fleet of coding agents ask each other questions through
GitHub issues instead of guessing.

| Skill | For | Use when |
|---|---|---|
| `github-coord-worker` | The agent implementing one issue | You hit something you shouldn't decide alone |
| `github-coord-lead` | The orchestrator running the epic | You need to find and answer whoever is waiting |

## The problem

Dispatch five subagents across five issues and the ones that hit an ambiguous
acceptance criterion have three bad options: guess, stall silently, or stop and
lose their context. None of those reach the orchestrator, because nobody is
watching a subagent's terminal.

The issue thread is the one place a message reliably lands, so that's the channel.

## How it works

**Comments carry the message.** Each request, response, and acknowledgement opens
with an HTML-comment marker naming a request ID:

```markdown
<!-- agent-coordination:request
request_id: REQ-42-20260803T171204Z-claude-worker-2
type: decision
status: open
-->
```

The ID (`REQ-<issue>-<UTC timestamp>-<agent>`) is what pairs an answer to its
question. Pairing is order-aware: a response only closes a request if it appears
*after* it, so a stale earlier comment can't make a new question look answered.

**Three labels carry the signal.** They're level-triggered — each asserts a
condition true *right now*, not an event that happened:

| Label | Means |
|---|---|
| `coord:needs-attention` | At least one unresolved request lives here |
| `coord:blocked` | This issue cannot make dependency-safe progress |
| `coord:follow-up-proposed` | A proposed follow-up issue awaits disposition |

**Permissions are asymmetric on purpose.** Workers may *add* those three labels
and nothing else — no removals, no milestones, no assignments, no issue-state
changes. The orchestrator owns every one of those. That asymmetry is what makes
the labels trustworthy: a worker that could clear its own signal is a worker whose
request can vanish before anyone reads it.

## Install

**Claude Code**

```
/plugin marketplace add pmcfadin/pmcfadin-skills
/plugin install github-coord@pmcfadin-skills
```

**Codex**

```sh
codex plugin marketplace add pmcfadin/pmcfadin-skills
codex plugin add github-coord@pmcfadin-skills
```

Needs `gh` authenticated with `repo` scope, and Python 3.8+ for `scripts/coord.py`
(stdlib only). See the [repo README](../../README.md#install) for manual install,
verification, updating, and the one-time `gh label create` setup each coordinated
repo needs.

## `scripts/coord.py`

Everything in these skills is plain `gh` except three jobs that are too
error-prone to do by hand. Each skill ships its own copy of the script.

```sh
coord.py threads   --repo O/N --issue N     # pair requests to responses; list what's unanswered
coord.py sweep     --repo O/N [--deep]      # find signaled issues, ranked by cost of delay
coord.py reconcile --repo O/N --issue N \
  --remove coord:needs-attention            # clear labels, but only when it's safe
```

`reconcile` is the interesting one. Before removing `coord:needs-attention` it
re-fetches the thread and refuses if any request still lacks a later response —
that closes the race where a second worker posts a request between the lead's read
and its write, leaving that worker with no signal left to raise. It also refuses to
touch any label outside the `coord:*` set. Override with `--force` when a request
is genuinely withdrawn, and say why in a comment.

The script saves tokens and catches that race. It is not load-bearing: an agent
that can't find it can run the equivalent `gh` commands and read the threads
itself.

## Setting up a repo

Workers can only add labels that exist, so define all three before dispatching
anyone. The lead skill has the exact `gh label create` calls.

## License

Apache-2.0
