# Lead response playbook

## Response template

```markdown
<!-- agent-coordination:response
request_id: REQ-...
status: resolved
-->

## Orchestrator response

- **Request ID:** `REQ-...`
- **Disposition:** approved | declined | clarified | follow-up-created | owner-input-required
- **Decision:** <authoritative answer>
- **Basis:** <specification, plan, issue contract, code, or owner decision>
- **Worker action:** <the specific next action>
- **Scope effect:** none | changed as described
- **Follow-up:** #<issue> | not required
- **Labels reconciled:** <removed or retained, and why if retained>
```

The `request_id` must match the request exactly — that pairing is how the worker
finds its answer and how `coord.py threads` decides the request is closed. Use
`status: resolved` when the worker can act on this alone; `status: pending-owner`
when you are handing it to a human, so a later sweep still counts it open.

## Dispositions

| Disposition | Use when | Labels |
|---|---|---|
| `approved` | The worker's recommendation stands | Clear `needs-attention` (if no other open request) and `blocked` |
| `declined` | You chose a different option, or the work is out of scope | Same as approved — declining is still an answer |
| `clarified` | A fact resolved it; no choice was needed | Same |
| `follow-up-created` | You filed the proposed issue | Also clear `follow-up-proposed`; include the number |
| `owner-input-required` | The sources genuinely cannot decide | Retain `needs-attention` and any `blocked`; say what you asked the human |

A declined follow-up still clears `coord:follow-up-proposed` — the disposition is
what the label tracks, not the outcome. Record the reason so the next worker who
notices the same gap doesn't re-propose it.

## Judgment notes

**Answer with authority, cite the source.** "Use per-API-key, per epic #38 Wave 2
bullet 3" teaches the worker the hierarchy; "let's go with API key" leaves it
guessing next time.

**Fix the contradiction the worker surfaced.** If a worker found the spec and the
plan disagreeing, deciding for that worker resolves one issue and leaves the
landmine for the next. Correct the stale document, or file a follow-up to do it,
and say which in the response.

**Don't widen scope by accident.** If your answer requires work outside the issue's
acceptance criteria, mark `Scope effect: changed as described`, say what moved, and
update the issue contract. Silent scope growth shows up later as an issue that
can't pass its own criteria.

**Prefer unblocking over perfecting.** A worker with two thirds of its work
independent needs a decision on the one third, not a redesign. Answer the question
asked; open a separate thread for anything else you noticed.

## Worked example

Answering the `REQ-42-...` decision request about rate-limit keying (worker
example in the `github-coord-worker` skill), where epic #38's plan says per API
key and `docs/api.md:88` says per source IP:

```markdown
<!-- agent-coordination:response
request_id: REQ-42-20260803T171204Z-claude-worker-2
status: resolved
-->

## Orchestrator response

- **Request ID:** `REQ-42-20260803T171204Z-claude-worker-2`
- **Disposition:** approved
- **Decision:** Key the ingest rate limit on API key, as recommended in option A.
  Resolve the key via `auth.resolve_key` before the limiter runs and reuse the
  cached value; do not add a second lookup.
- **Basis:** Epic #38 plan, Wave 2 bullet 3 ("100 req/min per API key"), which
  states tenant isolation as the wave's goal. `docs/api.md:88` is stale — it
  predates the multi-tenant work in #31 and is not authoritative here.
- **Worker action:** Implement `ratelimit/key.py` keyed on API key and extend
  `tests/test_ingest.py:210` to assert that two keys from the same source IP get
  independent budgets. Leave `docs/api.md` alone.
- **Scope effect:** none — this is within #42's existing acceptance criteria.
- **Follow-up:** #57 (correct `docs/api.md` rate-limit section; docs-only, does
  not block #42 acceptance)
- **Labels reconciled:** removing `coord:needs-attention`; `coord:blocked` was not
  set since two thirds of the work was independent.
```

Then, after re-reading the thread to confirm nothing new arrived:

```sh
gh issue comment 42 --repo acme/ingest --body-file /tmp/resp-42.md
python3 "$COORD" reconcile \
  --repo acme/ingest --issue 42 --remove coord:needs-attention
```

Note the two things this response did beyond answering: it filed #57 so the stale
doc that caused the confusion actually gets fixed, and it added a test assertion
that pins the decision down — the original acceptance test passed under either
interpretation, which is why the ambiguity survived to reach a worker.
