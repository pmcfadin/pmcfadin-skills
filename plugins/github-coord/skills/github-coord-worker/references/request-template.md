# Worker comment templates

Three comment kinds, each opened by an HTML-comment marker. The marker is what
makes the thread machine-readable: `coord.py threads` and the lead's sweep pair
requests to responses by `request_id`, so a comment without a well-formed marker
never shows up as answered or unanswered. The prose below the marker is what the
human or lead actually reads.

Marker rules that matter:

- `request_id` must be identical across the request, its response, and its ack.
- One marker per comment. Two requests in one comment cannot be answered
  separately.
- Keep the marker at the very top so it survives quoting and truncation.

## Request

```markdown
<!-- agent-coordination:request
request_id: REQ-<issue>-<timestamp>-<agent>
type: question|decision|blocker|follow-up|concern
status: open
-->

## Agent request: <type>

- **Request ID:** `REQ-...`
- **Agent:** <agent identity>
- **Issue:** #<number>
- **Branch/worktree:** <branch> — <absolute path>
- **Execution status:** continuing | partially blocked | fully blocked
- **Question or concern:** <one precise statement>
- **Evidence:** <commands and output, file:line links, or the conflicting plan text>
- **Options considered:** <A: … tradeoff; B: … tradeoff>
- **Recommendation:** <preferred resolution and why>
- **Impact if unanswered:** <what cannot proceed, or what risk stays open>
- **Safe work continuing:** <specific work continuing, or "none">
- **Follow-up scope:** <only for type: follow-up — see the checklist below>
```

Choosing `type`:

- `question` — you need a fact you cannot derive from spec, plan, or code.
- `decision` — two defensible options, and the choice is not yours to make.
- `blocker` — no dependency-safe work remains on this issue.
- `follow-up` — real work that belongs in its own issue.
- `concern` — you can proceed, but the lead should know a risk exists.

`type: blocker` and the `coord:blocked` label travel together. If safe work
remains, you are `partially blocked` and the label does not apply.

### Follow-up proposals

For `type: follow-up`, `Follow-up scope` must let the lead decide without asking
you anything:

- why this is outside the active issue's scope;
- whether it blocks current acceptance (usually: no);
- exact proposed scope, stated as work, not as a wish;
- affected files or components;
- dependencies, including which issues must land first;
- suggested acceptance criteria;
- verification expectations (tests, manual checks);
- security or compatibility implications.

## Acknowledgement

```markdown
<!-- agent-coordination:ack
request_id: REQ-...
-->

Acknowledged `REQ-...`.

- **Action taken:** <what happens next, concretely>
- **Status:** resumed | still blocked
- **Remaining concern:** none | <what is still open>
```

Still blocked → post a **new** request with a new ID rather than editing this
ack, and re-add `coord:needs-attention`. The lead's pairing logic reads the last
response after each request; reusing the answered ID would leave you looking
resolved.

## Worked example

Context: worker on #42 (`feat: rate-limit the ingest endpoint`) finds the epic
plan says 100 req/min per API key, while the spec in `docs/api.md:88` says per
source IP. Both are implementable; they behave differently under NAT, and the
acceptance test asserts neither.

```markdown
<!-- agent-coordination:request
request_id: REQ-42-20260803T171204Z-claude-worker-2
type: decision
status: open
-->

## Agent request: decision

- **Request ID:** `REQ-42-20260803T171204Z-claude-worker-2`
- **Agent:** claude-worker-2
- **Issue:** #42
- **Branch/worktree:** `feat/42-ingest-rate-limit` — `/Users/me/wt/42-ingest-rate-limit`
- **Execution status:** partially blocked
- **Question or concern:** Should the ingest rate limit key on API key or on source IP?
- **Evidence:** Epic #38 plan, "Wave 2" bullet 3: "100 req/min per API key".
  `docs/api.md:88`: "requests are limited per source IP". The acceptance test in
  `tests/test_ingest.py:210` asserts only a 429 status, so it passes either way.
  Behavior diverges for NAT'd customers: per-IP throttles a whole office to one
  key's budget.
- **Options considered:**
  A — key on API key: matches the epic plan, isolates tenants, needs the key
  resolved before the limiter runs (one extra lookup in the hot path).
  B — key on source IP: matches `docs/api.md`, cheaper, but collapses all NAT'd
  users of a shared egress IP into one bucket.
- **Recommendation:** A. Tenant isolation is the stated goal of epic #38, and the
  extra lookup is already cached in `auth.resolve_key`. If A is right, `docs/api.md:88`
  needs correcting — flagging rather than editing, since docs are outside this issue.
- **Impact if unanswered:** The limiter's key function and its tests cannot land.
  Choosing wrong means a rewrite of `ratelimit/key.py` plus its tests.
- **Safe work continuing:** Token-bucket store, Redis wiring, and the 429 response
  envelope — all key-agnostic. Not touching `ratelimit/key.py` until this is decided.
- **Follow-up scope:** n/a
```

Posted with:

```sh
gh issue comment 42 --repo acme/ingest --body-file /tmp/req-42.md
gh issue edit 42 --repo acme/ingest --add-label "coord:needs-attention"
```

No `coord:blocked`, because two thirds of the issue's work is genuinely
independent of the answer. Claiming a full block here would have pulled the lead
away from an issue that really was stuck.
