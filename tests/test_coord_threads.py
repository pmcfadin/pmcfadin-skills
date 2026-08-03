"""Pairing tests for coord.py's build_threads.

These cover the cases where getting it wrong loses a worker's request: a response
that predates its request must not close it, a marker in the issue body counts,
and a response with no request is reported rather than silently dropped.

Both skills ship a copy of coord.py; the tests run against each so the copies
can't drift apart unnoticed.
"""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPTS = sorted(ROOT.glob("plugins/*/skills/*/scripts/coord.py"))


def load(path):
    spec = importlib.util.spec_from_file_location(f"coord_{path.parent.parent.name}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def issue(body="", comments=()):
    return {
        "number": 1,
        "body": body,
        "author": {"login": "lead"},
        "comments": [{"body": b, "author": {"login": a}} for b, a in comments],
    }


def req(rid, type_="question"):
    return f"<!-- agent-coordination:request\nrequest_id: {rid}\ntype: {type_}\n-->\nbody"


def resp(rid, status="approved"):
    return f"<!-- agent-coordination:response\nrequest_id: {rid}\nstatus: {status}\n-->\nbody"


def ack(rid):
    return f"<!-- agent-coordination:ack\nrequest_id: {rid}\n-->\nbody"


class ThreadPairingTests(unittest.TestCase):
    def test_scripts_found(self):
        self.assertTrue(SCRIPTS, "no coord.py found under plugins/*/skills/*/scripts/")

    def test_copies_are_identical(self):
        bodies = {p.read_bytes() for p in SCRIPTS}
        self.assertEqual(len(bodies), 1, f"coord.py copies have drifted: {SCRIPTS}")

    def test_response_before_request_does_not_answer_it(self):
        for path in SCRIPTS:
            with self.subTest(path=path.parent.parent.name):
                coord = load(path)
                t = coord.build_threads(
                    issue(comments=[(resp("REQ-1-A"), "lead"), (req("REQ-1-A"), "w")])
                )
                self.assertEqual(len(t), 1)
                self.assertFalse(t[0]["answered"])

    def test_request_then_response_then_ack(self):
        for path in SCRIPTS:
            with self.subTest(path=path.parent.parent.name):
                coord = load(path)
                t = coord.build_threads(
                    issue(
                        comments=[
                            (req("REQ-1-B", "decision"), "w"),
                            (resp("REQ-1-B"), "lead"),
                            (ack("REQ-1-B"), "w"),
                        ]
                    )
                )
                self.assertTrue(t[0]["answered"])
                self.assertTrue(t[0]["acked"])
                self.assertEqual(t[0]["dispositions"], ["approved"])
                self.assertEqual(t[0]["type"], "decision")
                self.assertEqual(t[0]["requested_by"], "w")

    def test_marker_in_issue_body_is_indexed(self):
        for path in SCRIPTS:
            with self.subTest(path=path.parent.parent.name):
                coord = load(path)
                t = coord.build_threads(issue(body=req("REQ-1-C")))
                self.assertEqual(t[0]["request_id"], "REQ-1-C")
                self.assertFalse(t[0]["answered"])
                self.assertEqual(t[0]["requested_by"], "lead")

    def test_orphan_response_is_flagged(self):
        for path in SCRIPTS:
            with self.subTest(path=path.parent.parent.name):
                coord = load(path)
                t = coord.build_threads(issue(comments=[(resp("REQ-1-D"), "lead")]))
                self.assertTrue(t[0]["orphan_request"])

    def test_duplicate_request_marker_is_noise(self):
        """A worker re-posting the same ID shouldn't create a second thread or
        move the request later than the response that already answered it."""
        for path in SCRIPTS:
            with self.subTest(path=path.parent.parent.name):
                coord = load(path)
                t = coord.build_threads(
                    issue(
                        comments=[
                            (req("REQ-1-E"), "w"),
                            (resp("REQ-1-E"), "lead"),
                            (req("REQ-1-E"), "w"),
                        ]
                    )
                )
                self.assertEqual(len(t), 1)
                self.assertTrue(t[0]["answered"])

    def test_second_request_keeps_issue_unanswered(self):
        """The race the protocol exists to survive: one request answered, another
        still open on the same issue means the label must not be cleared."""
        for path in SCRIPTS:
            with self.subTest(path=path.parent.parent.name):
                coord = load(path)
                t = coord.build_threads(
                    issue(
                        comments=[
                            (req("REQ-1-F"), "w1"),
                            (resp("REQ-1-F"), "lead"),
                            (req("REQ-1-G"), "w2"),
                        ]
                    )
                )
                unanswered = [x["request_id"] for x in t if not x["answered"]]
                self.assertEqual(unanswered, ["REQ-1-G"])

    def test_marker_without_request_id_is_ignored(self):
        for path in SCRIPTS:
            with self.subTest(path=path.parent.parent.name):
                coord = load(path)
                t = coord.build_threads(
                    issue(comments=[("<!-- agent-coordination:request\ntype: question\n-->", "w")])
                )
                self.assertEqual(t, [])


if __name__ == "__main__":
    unittest.main()
