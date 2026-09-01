"""Reap-decision tests for tmux-lanes.

`reap` is the one command that can destroy work, and this is the branch that
decides whether it may. It has to say "landed" for a squash merge (an ancestry
check alone refuses those forever, which trains operators onto --force) without
ever saying it for work that has not landed, or for a state it cannot determine.

These build throwaway repos for each shape and drive cmd_reap through the same
source-and-call harness the parsing tests use.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "plugins/tmux-lanes/skills/tmux-lanes/scripts/tmux-lane.sh"

GIT_ENV = {
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
}


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        capture_output=True, text=True, env=dict(os.environ, **GIT_ENV), check=False,
    )


def build_repo(root: Path, diverge: bool = False, extra_on_base: bool = False,
               unicode_name: bool = False):
    """origin/main + a feature branch whose work was squash-merged into it.

    diverge=True leaves an unlanded change on the branch.
    extra_on_base=True lands an UNRELATED second commit on main afterwards,
    simulating another lane landing while this one waited to be reaped.
    """
    origin, work = root / "origin.git", root / "work"
    subprocess.run(["git", "init", "-q", "--bare", str(origin)], check=True)
    subprocess.run(["git", "clone", "-q", str(origin), str(work)], check=True)
    git(work, "symbolic-ref", "HEAD", "refs/heads/main")
    (work / "base.txt").write_text("base\n")
    git(work, "add", "-A"); git(work, "commit", "-qm", "base")
    git(work, "push", "-q", "origin", "main")

    git(work, "checkout", "-qb", "feature")
    lane_file = "café.md" if unicode_name else "lane.txt"
    (work / lane_file).write_text("lane work\n")
    git(work, "add", "-A"); git(work, "commit", "-qm", "lane c1")
    (work / lane_file).write_text("lane work v2\n")
    git(work, "add", "-A"); git(work, "commit", "-qm", "lane c2")

    git(work, "checkout", "-q", "main")
    git(work, "merge", "--squash", "feature")
    git(work, "commit", "-qm", "squashed lane (#1)")
    if extra_on_base:
        (work / "other-lane.txt").write_text("a different lane landed\n")
        git(work, "add", "-A"); git(work, "commit", "-qm", "another lane (#2)")
    git(work, "push", "-q", "origin", "main")
    git(work, "checkout", "-q", "feature")
    if diverge:
        (work / lane_file).write_text("never landed\n")
        git(work, "add", "-A"); git(work, "commit", "-qm", "unlanded")
    git(work, "remote", "set-head", "origin", "main")
    return work


def run_reap(state: Path, lane: str, workdir: Path, args=""):
    meta = state / f"{lane}.meta"
    meta.parent.mkdir(parents=True, exist_ok=True)
    meta.write_text(f"dir={workdir}\nissue=\n")
    env = dict(os.environ, TMUX_LANE_HOME=str(state.parent), TMUX_LANE_BASE_REF="origin/main", **GIT_ENV)
    return subprocess.run(
        ["bash", "-c", f'source "{SCRIPT}" 2>/dev/null; cmd_reap {lane} {args}'],
        capture_output=True, text=True, env=env,
    )


class ReapDecision(unittest.TestCase):
    def test_squash_merged_lane_is_allowed(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            work = build_repo(root)
            r = run_reap(root / "lane" / "state", "sq", work)
            self.assertIn("landed via squash", r.stdout, r.stdout + r.stderr)
            self.assertNotIn("REFUSED", r.stdout)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("reaped=", r.stdout)

    def test_still_allowed_after_another_lane_lands(self):
        """The multi-lane case: a whole-tree compare would refuse here."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            work = build_repo(root, extra_on_base=True)
            r = run_reap(root / "lane" / "state", "sq2", work)
            self.assertNotIn("REFUSED", r.stdout, r.stdout + r.stderr)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_unlanded_work_is_refused(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            work = build_repo(root, diverge=True)
            r = run_reap(root / "lane" / "state", "div", work)
            self.assertIn("REFUSED", r.stdout, r.stdout + r.stderr)

    def test_unlanded_work_in_non_ascii_path_is_refused(self):
        """git C-quotes non-ASCII paths; a quoted pathspec matches nothing, and
        an empty diff would be read as landed — reaping unlanded work."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            work = build_repo(root, diverge=True, unicode_name=True)
            r = run_reap(root / "lane" / "state", "uni", work)
            self.assertIn("REFUSED", r.stdout, r.stdout + r.stderr)

    def test_squash_merged_non_ascii_path_is_allowed(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            work = build_repo(root, unicode_name=True)
            r = run_reap(root / "lane" / "state", "uni2", work)
            self.assertNotIn("REFUSED", r.stdout, r.stdout + r.stderr)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_dirty_worktree_is_refused(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            work = build_repo(root)
            (work / "lane.txt").write_text("uncommitted edit\n")
            r = run_reap(root / "lane" / "state", "dirty", work)
            self.assertIn("REFUSED", r.stdout, r.stdout + r.stderr)
            self.assertIn("uncommitted", r.stdout)

    def test_unresolvable_base_is_refused(self):
        """Undeterminable is a refusal, not a pass."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            work = build_repo(root)
            env_state = root / "lane" / "state"
            env_state.mkdir(parents=True, exist_ok=True)
            (env_state / "nb.meta").write_text(f"dir={work}\nissue=\n")
            env = dict(
                os.environ, TMUX_LANE_HOME=str(root / "lane"),
                TMUX_LANE_BASE_REF="origin/does-not-exist", **GIT_ENV,
            )
            r = subprocess.run(
                ["bash", "-c", f'source "{SCRIPT}" 2>/dev/null; cmd_reap nb'],
                capture_output=True, text=True, env=env,
            )
            self.assertIn("REFUSED", r.stdout, r.stdout + r.stderr)


class ReapWorktree(unittest.TestCase):
    """--rm-worktree deletes a checkout, so it gets the same scrutiny as the gate."""

    def _lane_worktree(self, root: Path):
        """A real linked worktree on the squash-merged branch."""
        work = build_repo(root)
        git(work, "checkout", "-q", "main")
        wt = root / "lane-wt"
        git(work, "worktree", "add", "-q", str(wt), "feature")
        return work, wt

    def test_plain_reap_leaves_the_worktree(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            _, wt = self._lane_worktree(root)
            r = run_reap(root / "lane" / "state", "keep", wt)
            self.assertIn("worktree-left=", r.stdout, r.stdout + r.stderr)
            self.assertTrue(wt.exists())

    def test_rm_worktree_removes_a_landed_lane(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            _, wt = self._lane_worktree(root)
            r = run_reap(root / "lane" / "state", "rm", wt, args="--rm-worktree")
            self.assertIn("worktree-removed=", r.stdout, r.stdout + r.stderr)
            self.assertFalse(wt.exists())

    def test_force_rm_worktree_discards_a_dirty_tree(self):
        """Documented as destructive; assert it actually is, so the doc stays true."""
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            _, wt = self._lane_worktree(root)
            (wt / "lane.txt").write_text("uncommitted\n")
            r = run_reap(root / "lane" / "state", "frm", wt, args="--force --rm-worktree")
            self.assertIn("worktree-removed=", r.stdout, r.stdout + r.stderr)
            self.assertFalse(wt.exists())


if __name__ == "__main__":
    unittest.main()
