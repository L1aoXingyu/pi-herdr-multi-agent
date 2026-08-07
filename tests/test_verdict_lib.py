#!/usr/bin/env python3
"""Unit tests for verdict_lib (no herdr required)."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "herdr-multi-agent"))
import verdict_lib as vl  # noqa: E402


class VerdictLibTests(unittest.TestCase):
    def test_rejects_prompt_template(self):
        blob = """
End with:

VERDICT: ship | ship-with-fixes | hold
RISKS: <semicolon-separated must-fix before next tag, or N/A>
REQUIRED_FIXES: <semicolon-separated must-fix before next tag, or N/A>
CONFIDENCE: low|medium|high
"""
        self.assertIsNone(vl.extract_trailer(blob))

    def test_accepts_real_trailer(self):
        blob = """
Some review prose...

VERDICT: ship-with-fixes
RISKS: fleet defaults too personal; harvest false positive
REQUIRED_FIXES: add preflight; strict trailer parse
CONFIDENCE: high
"""
        t = vl.extract_trailer(blob)
        self.assertIsNotNone(t)
        assert t is not None
        self.assertIn("ship-with-fixes", t["verdict"])
        self.assertEqual(t["confidence"], "high")

    def test_prefers_last_valid_over_template(self):
        blob = """
VERDICT: ship | ship-with-fixes | hold
CONFIDENCE: low|medium|high

Later real answer:

VERDICT: hold
RISKS: harvest FP
REQUIRED_FIXES: strict parse
CONFIDENCE: high
"""
        t = vl.extract_trailer(blob)
        self.assertIsNotNone(t)
        assert t is not None
        self.assertEqual(t["verdict"], "hold")

    def test_check_outdir_skips_start_failed(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            (out / "agents.json").write_text(
                json.dumps(
                    [
                        {"name": "a", "start_status": "failed"},
                        {"name": "b", "start_status": "started"},
                    ]
                )
            )
            (out / "b").mkdir()
            (out / "b" / "verdict.md").write_text(
                "VERDICT: ship-with-fixes\nRISKS: n/a\nREQUIRED_FIXES: n/a\nCONFIDENCE: medium\n"
            )
            # invoke check via library
            ok_b, _ = vl.agent_has_valid_verdict(out, "b")
            self.assertTrue(ok_b)
            ok_a, _ = vl.agent_has_valid_verdict(out, "a", start_status="failed")
            self.assertFalse(ok_a)

    def test_policy_marker(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)
            (out / "policy.json").write_text(json.dumps({"verdict_marker": "FINDING:"}))
            self.assertEqual(vl.load_marker(out), "FINDING:")


if __name__ == "__main__":
    unittest.main()
