#!/usr/bin/env python3
"""Unit tests for cursor prompt-landed detection and non-pi recover policy.

Replays the 2026-08-18 k3max stack: first paste renamed the session to
"Routing File Reviewer" while herdr status stayed idle; a full re-prompt
then stacked Pasted text #2 / #3.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fleet_lib as fl  # noqa: E402

K3_PROMPT = """ROLE: Independent reviewer of a global routing file.
ONLY: Judge whether ~/.grok/AGENTS.md can be shortened.
FORBIDDEN: Edit any file. Do not run long jobs.

READ-ONLY REVIEW — do not edit files, do not run long jobs, do not start servers.

End with:

VERDICT: ship | ship-with-fixes | block
RISKS: ...
REQUIRED_FIXES: ...
CONFIDENCE: low|medium|high
"""

K3_PANE_AFTER_STACK = """
  VERDICT: ship-with-fixes
  RISKS: The L20 cut trades a cheap in-file reminder
  REQUIRED_FIXES: 1) Merge spawn_subagent
  CONFIDENCE: high


  [Pasted text #2 +44 lines]



  [Pasted text #3 +43 lines]


  This is the identical brief sent again (3rd copy).
"""

K3_COLD_PANE = """
  Run Everything
  Kimi K3 Max
  ~/clawd · main
"""


class TitleTests(unittest.TestCase):
    def test_cold_defaults(self):
        for t in ("", "Cursor Agent", "cursor-agent", "Agent", "  Cursor Agent  "):
            self.assertFalse(fl.title_left_cold(t), t)
            self.assertFalse(fl.prompt_already_landed(title=t), t)

    def test_k3_renamed_title(self):
        self.assertTrue(fl.title_left_cold("Routing File Reviewer"))
        self.assertTrue(fl.prompt_already_landed(title="Routing File Reviewer"))

    def test_spinner_stripped_title(self):
        self.assertTrue(fl.title_left_cold("- Routing File Reviewer"))


class PaneTests(unittest.TestCase):
    def test_pasted_text_marker(self):
        self.assertTrue(
            fl.prompt_already_landed(
                title="Cursor Agent",
                pane_text="[Pasted text #1 +44 lines]\nROLE: Independent reviewer",
            )
        )

    def test_k3_stack_fixture(self):
        self.assertTrue(
            fl.prompt_already_landed(
                title="Cursor Agent",
                pane_text=K3_PANE_AFTER_STACK,
                prompt_text=K3_PROMPT,
            )
        )

    def test_cold_chrome_not_landed(self):
        self.assertFalse(
            fl.prompt_already_landed(
                title="Cursor Agent",
                pane_text=K3_COLD_PANE,
                prompt_text=K3_PROMPT,
            )
        )

    def test_fingerprint_without_title_change(self):
        self.assertTrue(
            fl.prompt_already_landed(
                title="Cursor Agent",
                pane_text="ROLE: Independent reviewer of a global routing file.\nONLY: Judge",
                prompt_text=K3_PROMPT,
            )
        )

    def test_verdict_alone_is_not_land_evidence(self):
        # VERDICT lives in the template; must not count as a fingerprint.
        self.assertFalse(
            fl.prompt_already_landed(
                title="Cursor Agent",
                pane_text="End with:\nVERDICT: ship | ship-with-fixes | block\n",
                prompt_text=K3_PROMPT,
            )
        )


class PolicyTests(unittest.TestCase):
    def test_k3_timeline_never_repastes_once_landed(self):
        # Title already renamed by tick 1 (idle lag). Enter at 3, accept at 4.
        actions = [
            fl.nonpi_prompt_policy(idle_ticks=t, landed=True) for t in range(1, 8)
        ]
        self.assertEqual(
            actions,
            ["wait", "wait", "enter", "accept", "accept", "skip_repaste", "accept"],
        )
        self.assertNotIn("repaste", actions)

    def test_empty_composer_may_repaste_once(self):
        actions = [
            fl.nonpi_prompt_policy(idle_ticks=t, landed=False) for t in range(1, 8)
        ]
        self.assertEqual(
            actions,
            ["wait", "wait", "enter", "wait", "wait", "repaste", "wait"],
        )

    def test_timeout_empty_fails(self):
        self.assertEqual(
            fl.nonpi_prompt_policy(idle_ticks=30, landed=False), "fail"
        )

    def test_timeout_landed_accepts(self):
        self.assertEqual(
            fl.nonpi_prompt_policy(idle_ticks=30, landed=True), "accept"
        )

    def test_parent_must_not_third_paste(self):
        # After launch's one allowed empty-composer repaste, a later landed
        # idle is accept — parent playbook must not issue paste #3.
        self.assertEqual(
            fl.nonpi_prompt_policy(idle_ticks=7, landed=True), "accept"
        )


if __name__ == "__main__":
    unittest.main()
