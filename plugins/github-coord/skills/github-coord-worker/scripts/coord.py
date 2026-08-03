#!/usr/bin/env python3
"""Coordination helper for GitHub-issue-based agent messaging.

Wraps `gh` so leads and workers spend tokens on judgment, not on
re-deriving marker parsing and label bookkeeping every session.

Posting comments and adding labels is plain `gh` -- see the skill for those. This
script covers only the three jobs where getting it right by hand is error-prone:

  threads   Pair request/response/ack markers on one issue; report unanswered.
            Order-aware, so a response predating a request doesn't answer it.
  sweep     Find open issues with coordination signals, priority-ordered.
            --deep also names the unanswered request IDs on each.
  reconcile Remove coordination labels, refusing to clear needs-attention while
            any request is still unanswered (re-fetches first).

Every subcommand takes --repo OWNER/NAME. reconcile accepts --dry-run, which
prints the exact `gh` invocation instead of running it.
"""

import argparse
import json
import re
import shlex
import subprocess
import sys

LABELS = ("coord:needs-attention", "coord:blocked", "coord:follow-up-proposed")

MARKER_RE = re.compile(
    r"<!--\s*agent-coordination:(?P<kind>request|response|ack)\s*(?P<fields>.*?)-->",
    re.DOTALL,
)
FIELD_RE = re.compile(r"^\s*([a-z_]+)\s*:\s*(.+?)\s*$", re.MULTILINE)


def die(msg, code=1):
    print(f"coord: {msg}", file=sys.stderr)
    sys.exit(code)


def gh(args, dry_run=False, capture=True, check=True):
    cmd = ["gh"] + args
    if dry_run:
        print(" ".join(shlex.quote(c) for c in cmd))
        return ""
    proc = subprocess.run(cmd, capture_output=capture, text=True)
    if check and proc.returncode != 0:
        die((proc.stderr or proc.stdout or "gh failed").strip(), proc.returncode)
    return (proc.stdout or "").strip()


# --------------------------------------------------------------------------- #
# marker parsing


def parse_markers(body):
    """Yield (kind, fields dict) for each coordination marker in a comment."""
    for m in MARKER_RE.finditer(body or ""):
        fields = dict(FIELD_RE.findall(m.group("fields")))
        yield m.group("kind"), fields


def fetch_comments(repo, issue):
    raw = gh(
        [
            "issue",
            "view",
            str(issue),
            "--repo",
            repo,
            "--json",
            "number,title,url,labels,state,milestone,body,author,createdAt,comments",
        ]
    )
    return json.loads(raw)


def build_threads(issue_data):
    """Collapse an issue's comments into one record per request_id.

    Ordering matters: a response only counts if it appears after the request
    it names, so a stale earlier comment can't mark a new request answered.
    """
    threads = {}
    order = []
    events = []

    body_and_comments = [
        {
            "body": issue_data.get("body") or "",
            "author": issue_data.get("author") or {},
            "createdAt": issue_data.get("createdAt", ""),
            "url": issue_data.get("url", ""),
        }
    ] + list(issue_data.get("comments") or [])

    for idx, c in enumerate(body_and_comments):
        for kind, fields in parse_markers(c.get("body", "")):
            rid = fields.get("request_id")
            if not rid:
                continue
            events.append(
                {
                    "idx": idx,
                    "kind": kind,
                    "request_id": rid,
                    "fields": fields,
                    "author": (c.get("author") or {}).get("login", "?"),
                    "createdAt": c.get("createdAt", ""),
                    "url": c.get("url", ""),
                }
            )

    for ev in events:
        rid = ev["request_id"]
        if rid not in threads:
            threads[rid] = {
                "request_id": rid,
                "type": None,
                "requested_by": None,
                "request_idx": None,
                "request_url": None,
                "responses": [],
                "acks": [],
            }
            order.append(rid)
        t = threads[rid]
        if ev["kind"] == "request":
            # First request marker wins; re-posts of the same ID are noise.
            if t["request_idx"] is None:
                t["type"] = ev["fields"].get("type")
                t["requested_by"] = ev["author"]
                t["request_idx"] = ev["idx"]
                t["request_url"] = ev["url"]
        elif ev["kind"] == "response":
            t["responses"].append(ev)
        else:
            t["acks"].append(ev)

    out = []
    for rid in order:
        t = threads[rid]
        req_idx = t["request_idx"]
        after = [
            r
            for r in t["responses"]
            if req_idx is None or r["idx"] > req_idx
        ]
        t["answered"] = bool(after)
        t["response_urls"] = [r["url"] for r in after]
        t["dispositions"] = [
            r["fields"].get("status") for r in after if r["fields"].get("status")
        ]
        t["acked"] = bool(
            [a for a in t["acks"] if after and a["idx"] > after[-1]["idx"]]
        )
        t["orphan_request"] = req_idx is None
        out.append(t)
    return out


# --------------------------------------------------------------------------- #
# subcommands


def cmd_threads(a):
    data = fetch_comments(a.repo, a.issue)
    threads = build_threads(data)
    labels = [l["name"] for l in data.get("labels") or []]
    if a.json:
        print(
            json.dumps(
                {
                    "issue": data.get("number"),
                    "title": data.get("title"),
                    "url": data.get("url"),
                    "state": data.get("state"),
                    "labels": labels,
                    "threads": [
                        {
                            k: t[k]
                            for k in (
                                "request_id",
                                "type",
                                "requested_by",
                                "answered",
                                "acked",
                                "dispositions",
                                "response_urls",
                                "orphan_request",
                            )
                        }
                        for t in threads
                    ],
                },
                indent=2,
            )
        )
        return

    unanswered = [t for t in threads if not t["answered"]]
    print(f"#{data.get('number')} {data.get('title')}  [{data.get('state')}]")
    print(f"labels: {', '.join(labels) or '(none)'}")
    print(f"threads: {len(threads)}  unanswered: {len(unanswered)}")
    for t in threads:
        mark = "OPEN " if not t["answered"] else "done "
        extra = []
        if t["dispositions"]:
            extra.append("/".join(t["dispositions"]))
        if t["answered"] and not t["acked"]:
            extra.append("no-ack")
        if t["orphan_request"]:
            extra.append("response-without-request")
        suffix = f"  ({'; '.join(extra)})" if extra else ""
        print(f"  {mark}{t['request_id']}  type={t['type']}  by={t['requested_by']}{suffix}")
    print()
    print(
        "safe-to-clear-needs-attention: "
        + ("yes" if not unanswered else f"no ({len(unanswered)} open)")
    )


PRIORITY_LABEL_RANK = {
    "coord:blocked": 0,
    "coord:follow-up-proposed": 2,
}


def _list(a, search):
    raw = gh(
        [
            "issue",
            "list",
            "--repo",
            a.repo,
            "--search",
            search,
            "--limit",
            str(a.limit),
            "--json",
            "number,title,url,labels,updatedAt,milestone,assignees",
        ]
    )
    return json.loads(raw or "[]")


def cmd_sweep(a):
    search = 'state:open label:"coord:needs-attention"'
    if a.milestone:
        search += f' milestone:"{a.milestone}"'
    if a.epic:
        search += f" #{a.epic}"
    if a.extra_search:
        search += " " + a.extra_search
    issues = _list(a, search)

    # `#N` matches issues *referencing* N -- and an epic does not reference
    # itself, so a worker's escalation on the epic is invisible to the epic's own
    # sweep. Fetch the epic separately and fold it in.
    if a.epic and not any(str(i["number"]) == str(a.epic) for i in issues):
        for i in _list(a, f'state:open label:"coord:needs-attention"'):
            if str(i["number"]) == str(a.epic):
                issues.append(i)

    for i in issues:
        names = [l["name"] for l in i.get("labels") or []]
        i["coord_labels"] = [n for n in names if n.startswith("coord:")]
        i["rank"] = min(
            [PRIORITY_LABEL_RANK.get(n, 1) for n in i["coord_labels"]] or [1]
        )
    issues.sort(key=lambda i: (i["rank"], i.get("updatedAt", "")))

    if a.deep:
        for i in issues:
            try:
                t = build_threads(fetch_comments(a.repo, i["number"]))
            except SystemExit:
                t = []
            i["threads"] = [x["request_id"] for x in t]
            i["unanswered"] = [x["request_id"] for x in t if not x["answered"]]
            i["types"] = sorted({x["type"] for x in t if not x["answered"] and x["type"]})

    if a.json:
        print(json.dumps(issues, indent=2))
        return

    if not issues:
        print(f"no open coord:needs-attention issues in {a.repo} for search: {search}")
        return
    print(f"{len(issues)} signaled issue(s) in {a.repo}  [search: {search}]")
    for i in issues:
        ms = (i.get("milestone") or {}).get("title") or "-"
        print(f"\n#{i['number']} {i['title']}")
        print(f"  {i['url']}")
        print(
            f"  coord: {', '.join(i['coord_labels'])}  milestone: {ms}  updated: {i.get('updatedAt')}"
        )
        if a.deep:
            if i["unanswered"]:
                print(
                    f"  unanswered ({len(i['unanswered'])}): {', '.join(i['unanswered'])}"
                )
                if i["types"]:
                    print(f"  types: {', '.join(i['types'])}")
            else:
                print("  unanswered: none -- labels are stale, safe to clear")


def cmd_reconcile(a):
    labels = a.remove or []
    bad = [l for l in labels if l not in LABELS]
    if bad:
        die(f"refusing to touch non-coordination labels: {', '.join(bad)}")
    if not labels:
        die("nothing to remove; pass --remove coord:needs-attention (repeatable)")
    if not a.force:
        threads = build_threads(fetch_comments(a.repo, a.issue))
        unanswered = [t["request_id"] for t in threads if not t["answered"]]
        if "coord:needs-attention" in labels and unanswered:
            die(
                "re-fetched comments still show unanswered requests: "
                + ", ".join(unanswered)
                + "\nanswer them or pass --force with a stated reason"
            )
    cmd = ["issue", "edit", str(a.issue), "--repo", a.repo]
    for l in labels:
        cmd += ["--remove-label", l]
    gh(cmd, dry_run=a.dry_run)
    if not a.dry_run:
        print(f"removed from #{a.issue}: {', '.join(labels)}")


# --------------------------------------------------------------------------- #


def main():
    p = argparse.ArgumentParser(prog="coord.py", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    def add(name, fn, needs_repo=True, needs_issue=False, writes=False):
        s = sub.add_parser(name, help=fn.__doc__ or name)
        if needs_repo:
            s.add_argument("--repo", required=True, help="OWNER/NAME")
        if needs_issue:
            s.add_argument("--issue", required=True, help="issue number")
        if writes:
            s.add_argument("--dry-run", action="store_true")
        s.set_defaults(func=fn)
        return s

    s = add("threads", cmd_threads, needs_issue=True)
    s.add_argument("--json", action="store_true")

    s = add("sweep", cmd_sweep)
    s.add_argument("--epic", help="epic issue number to scope the search to")
    s.add_argument("--milestone", help="milestone title to scope the search to")
    s.add_argument("--extra-search", help="extra GitHub search qualifiers")
    s.add_argument("--limit", type=int, default=100)
    s.add_argument(
        "--deep",
        action="store_true",
        help="also read each issue's comments and report unanswered request IDs",
    )
    s.add_argument("--json", action="store_true")

    s = add("reconcile", cmd_reconcile, needs_issue=True, writes=True)
    s.add_argument(
        "--remove", action="append", help="coord:* label to remove (repeatable)"
    )
    s.add_argument(
        "--force",
        action="store_true",
        help="skip the unanswered-request safety re-check",
    )

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
