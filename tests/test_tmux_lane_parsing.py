"""Pane-parsing tests for tmux-lanes.

The bug these exist to prevent: `start`'s readiness check was a regex requiring a
literally empty '❯' input line. Claude Code 2.1.252 began drawing a dim
suggestion hint there, the regex stopped matching, and `start` silently never
sent its prompt — on every lane, with no signal until someone peeked at a pane.
Nothing in CI exercised the parsing, so the break was invisible.

These feed recorded `tmux capture-pane -e` shapes through the shell functions so
the next upstream rendering change fails here instead of in production.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "plugins/tmux-lanes/skills/tmux-lanes/scripts/tmux-lane.sh"

ESC = "\x1b"
DIM = f"{ESC}[2m"
RESET = f"{ESC}[0m"
FG = f"{ESC}[39m"

# --- recorded pane shapes -------------------------------------------------
EMPTY_INPUT = f"{FG}❯ {RESET}"
DIM_PLACEHOLDER = f'{FG}❯ {DIM}Try "fix typecheck errors"{RESET}'
QUEUED_INPUT = f"{FG}❯ {RESET}run the e2e mock gate too"
TRUST_DIALOG = "\n".join(
    [
        " Quick safety check: Is this a project you created or one you trust?",
        f"{FG} ❯ {RESET}No, exit",
        "   Yes, I trust this folder",
        " Enter to confirm · Esc to cancel",
    ]
)
NUMBERED_DIALOG = "\n".join([f"{FG}❯ {DIM}1. Yes{RESET}", "  2. No"])
# Same attribute, emitted as a later SGR parameter. A renderer is free to write
# it this way; matching only "2 is the first parameter" would put start back to
# timing out with the suite still green.
DIM_LATE_PARAM = f'{FG}❯ {ESC}[39;2mTry "fix typecheck errors"{RESET}'
# 24-bit and 256-colour introducers carry a literal "2" as a SUB-parameter. A
# "2 anywhere in the parameters" test reads these as dim, so real typed text
# drawn in truecolour would be called ready and masked away in peek.
TRUECOLOR_INPUT = f"{FG}❯ {ESC}[38;2;175;175;175mrun the gate{RESET}"
COLOR256_INPUT = f"{FG}❯ {ESC}[38;5;2mrun the gate{RESET}"


def sh(func: str, stdin: str):
    """Source the script and run one function with stdin, in an isolated HOME.

    Asserts the function exists first. Without that guard a rename yields 127,
    which satisfies every "not ready" assertion below — the negative suite would
    stay green against a script whose functions had vanished.
    """
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, TMUX_LANE_HOME=tmp)
        name = func.split()[0]
        probe = subprocess.run(
            ["bash", "-c", f'source "{SCRIPT}" >/dev/null 2>&1; declare -F {name}'],
            capture_output=True, text=True, env=env,
        )
        if probe.returncode != 0:
            raise AssertionError(f"{name} is not defined after sourcing {SCRIPT}")
        return subprocess.run(
            ["bash", "-c", f'source "{SCRIPT}" 2>/dev/null; {func}'],
            input=stdin,
            capture_output=True,
            text=True,
            env=env,
        )


class TuiReadyText(unittest.TestCase):
    def test_empty_input_line_is_ready(self):
        self.assertEqual(sh("tui_ready_text", EMPTY_INPUT).returncode, 0)

    def test_dim_placeholder_is_ready(self):
        """The regression: a dim hint is not user input, so the TUI is ready."""
        self.assertEqual(sh("tui_ready_text", DIM_PLACEHOLDER).returncode, 0)

    def test_queued_input_is_not_ready(self):
        self.assertEqual(sh("tui_ready_text", QUEUED_INPUT).returncode, 1)

    def test_trust_dialog_is_not_ready(self):
        self.assertEqual(sh("tui_ready_text", TRUST_DIALOG).returncode, 1)

    def test_numbered_dialog_row_is_not_ready(self):
        """'❯' also marks a selected dialog option; a dialog is never ready."""
        self.assertEqual(sh("tui_ready_text", NUMBERED_DIALOG).returncode, 1)

    def test_dim_as_later_sgr_parameter_is_ready(self):
        """\\e[39;2m is the same attribute as \\e[2m."""
        self.assertEqual(sh("tui_ready_text", DIM_LATE_PARAM).returncode, 0)

    def test_dim_unnumbered_dialog_is_not_ready(self):
        """The trust dialog is arrow-selected and unnumbered; a dim selected row
        must not read as ready or start fires its prompt into the dialog."""
        pane = "\n".join([
            " Quick safety check: Is this a project you created or one you trust?",
            f"{FG}❯ {DIM}No, exit{RESET}",
            "   Yes, I trust this folder",
            " Enter to confirm · Esc to cancel",
        ])
        self.assertEqual(sh("tui_ready_text", pane).returncode, 1)

    def test_emphasised_dialog_footer_is_still_detected(self):
        """A footer with bold key names must not slip past the dialog probe."""
        pane = "\n".join([
            f"{FG}❯ {DIM}No, exit{RESET}",
            f" {ESC}[1mEnter{ESC}[22m to confirm · {ESC}[1mEsc{ESC}[22m to cancel",
        ])
        self.assertEqual(sh("tui_ready_text", pane).returncode, 1)

    def test_truecolor_input_is_not_ready(self):
        """\\e[38;2;R;G;Bm is a colour, not dim — this is real queued input."""
        self.assertEqual(sh("tui_ready_text", TRUECOLOR_INPUT).returncode, 1)

    def test_256color_input_is_not_ready(self):
        self.assertEqual(sh("tui_ready_text", COLOR256_INPUT).returncode, 1)

    def test_empty_pane_is_not_ready(self):
        self.assertEqual(sh("tui_ready_text", "").returncode, 1)


class PeekRender(unittest.TestCase):
    def test_dim_placeholder_is_masked(self):
        out = sh("peek_render", DIM_PLACEHOLDER).stdout
        self.assertIn("(empty", out)
        self.assertNotIn("fix typecheck errors", out)

    def test_real_input_is_preserved(self):
        """Never hide what someone actually typed into the lane."""
        out = sh("peek_render", QUEUED_INPUT).stdout
        self.assertIn("run the e2e mock gate too", out)
        self.assertNotIn("(empty", out)

    def test_dialog_selection_is_preserved(self):
        """Masking a selected row would leave the lead keying blind."""
        out = sh("peek_render", NUMBERED_DIALOG).stdout
        self.assertIn("1. Yes", out)
        self.assertNotIn("(empty", out)

    def test_dim_unnumbered_dialog_row_is_preserved(self):
        """The trust dialog is arrow-selected and unnumbered; if its selected row
        renders dim, masking it would leave the lead keying blind."""
        pane = "\n".join([
            " Quick safety check: Is this a project you created or one you trust?",
            f"{FG}❯ {DIM}No, exit{RESET}",
            "   Yes, I trust this folder",
            " Enter to confirm · Esc to cancel",
        ])
        out = sh("peek_render", pane).stdout
        self.assertIn("No, exit", out)
        self.assertNotIn("(empty", out)

    def test_truecolor_input_is_not_masked(self):
        """Masking this would tell the lead the lane is empty with work queued."""
        out = sh("peek_render", TRUECOLOR_INPUT).stdout
        self.assertIn("run the gate", out)
        self.assertNotIn("(empty", out)

    def test_osc8_hyperlinks_are_stripped(self):
        """capture-pane -e emits OSC 8; Claude Code uses it for its session link,
        so peek would otherwise print raw ]8;id=...;https://... fragments."""
        pane = f"status {ESC}]8;id=q;https://x/y{ESC}\\/rc{ESC}]8;;{ESC}\\ end"
        out = sh("peek_render", pane).stdout
        self.assertNotIn("]8;", out)
        self.assertNotIn("https://x/y", out)
        self.assertIn("status", out)

    def test_escapes_are_stripped(self):
        self.assertNotIn(ESC, sh("peek_render", TRUST_DIALOG).stdout)


if __name__ == "__main__":
    unittest.main()
