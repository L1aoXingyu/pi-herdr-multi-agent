#!/usr/bin/env python3
"""Unit tests for fleet_lib (no herdr required)."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "skills" / "herdr-multi-agent"))
import fleet_lib as fl  # noqa: E402


class ParseKindModelTests(unittest.TestCase):
    def test_pi_provider_model_thinking(self):
        self.assertEqual(
            fl.parse_kind_model("openai-codex/gpt-5.6-sol:xhigh"),
            ("pi", "openai-codex/gpt-5.6-sol:xhigh"),
        )
        self.assertEqual(
            fl.parse_kind_model("opencode-go/kimi-k3:max"),
            ("pi", "opencode-go/kimi-k3:max"),
        )
        self.assertEqual(
            fl.parse_kind_model("siliconflow/deepseek-ai/DeepSeek-V4-Pro:high"),
            ("pi", "siliconflow/deepseek-ai/DeepSeek-V4-Pro:high"),
        )

    def test_explicit_cursor_kind(self):
        self.assertEqual(
            fl.parse_kind_model("cursor:claude-fable-5-thinking-high"),
            ("cursor", "claude-fable-5-thinking-high"),
        )

    def test_empty_model_after_kind_errors(self):
        with self.assertRaises(fl.FleetError):
            fl.parse_kind_model("cursor:")
        with self.assertRaises(fl.FleetError):
            fl.parse_kind_model("cursor:   ")

    def test_unknown_bare_prefix_not_kind(self):
        # not a herdr kind → whole string is the model under default kind
        self.assertEqual(
            fl.parse_kind_model("notakind:foo-bar"),
            ("pi", "notakind:foo-bar"),
        )

    def test_global_non_pi_kind_cannot_rebrand_provider_model(self):
        self.assertEqual(
            fl.parse_kind_model("openai-codex/gpt-5.6-sol:xhigh", default="cursor"),
            ("pi", "openai-codex/gpt-5.6-sol:xhigh"),
        )

    def test_uppercase_kind_not_matched_as_kind(self):
        # kinds are lowercase set membership; uppercase stays full model
        kind, model = fl.parse_kind_model("CURSOR:claude-fable-5-high")
        self.assertEqual(kind, "pi")
        self.assertEqual(model, "CURSOR:claude-fable-5-high")

    def test_parse_agent_spec(self):
        short, kind, model = fl.parse_agent_spec(
            "fable5=cursor:claude-fable-5-thinking-high"
        )
        self.assertEqual(short, "fable5")
        self.assertEqual(kind, "cursor")
        self.assertEqual(model, "claude-fable-5-thinking-high")
        short, kind, model = fl.parse_agent_spec("k3max=cursor:kimi-k3-max")
        self.assertEqual((short, kind, model), ("k3max", "cursor", "kimi-k3-max"))
        short, kind, model = fl.parse_agent_spec("g37flash=agy:gemini-3.7-flash-high")
        self.assertEqual((short, kind, model), ("g37flash", "agy", "gemini-3.7-flash-high"))
        short, kind, model = fl.parse_agent_spec("g38flash=cursor:gemini-3.8-flash-high")
        self.assertEqual((short, kind, model), ("g38flash", "cursor", "gemini-3.8-flash-high"))
        short, kind, model = fl.parse_agent_spec("glm53=siliconflow/zai-org/GLM-5.3:max")
        self.assertEqual((short, kind, model), ("glm53", "pi", "siliconflow/zai-org/GLM-5.3:max"))


class MatchModelTests(unittest.TestCase):
    PI_HAY = """
Available models:
openai-codex/gpt-5.6-sol
opencode-go/kimi-k3
siliconflow/deepseek-ai/DeepSeek-V4-Pro
deepseek/deepseek-v4-flash
"""

    CURSOR_HAY = """
Available models

claude-fable-5-thinking-high - Fable 5 1M Thinking (NO ZDR)
claude-fable-5-high - Fable 5 1M (NO ZDR)
claude-fable-5-thinking-xhigh - Fable 5 1M Extra High Thinking (NO ZDR)
kimi-k3-max - Kimi K3
kimi-k3-high - Kimi K3 High
gpt-5.5-high - GPT-5.5 1M High
gemini-3.8-flash-high - Gemini 3.8 Flash High
gemini-3.8-flash-medium - Gemini 3.8 Flash Medium
gemini-3.8-flash-low - Gemini 3.8 Flash Low
"""

    def test_pi_matches_with_thinking_suffix(self):
        self.assertTrue(
            fl.match_model(self.PI_HAY, "openai-codex/gpt-5.6-sol:xhigh", "pi")
        )
        self.assertTrue(fl.match_model(self.PI_HAY, "opencode-go/kimi-k3:max", "pi"))

    def test_pi_rejects_unknown(self):
        self.assertFalse(fl.match_model(self.PI_HAY, "openai-codex/nope:xhigh", "pi"))

    def test_cursor_exact_id_only(self):
        self.assertTrue(
            fl.match_model(self.CURSOR_HAY, "claude-fable-5-thinking-high", "cursor")
        )
        self.assertTrue(fl.match_model(self.CURSOR_HAY, "claude-fable-5-high", "cursor"))
        self.assertTrue(fl.match_model(self.CURSOR_HAY, "kimi-k3-max", "cursor"))
        self.assertTrue(fl.match_model(self.CURSOR_HAY, "gemini-3.8-flash-high", "cursor"))
        self.assertFalse(fl.match_model(self.CURSOR_HAY, "kimi-k3", "cursor"))
        self.assertFalse(fl.match_model(self.CURSOR_HAY, "gemini-3.8-flash", "cursor"))
        # substring / prefix must not match a different id
        self.assertFalse(
            fl.match_model(self.CURSOR_HAY, "claude-fable-5-thinking", "cursor")
        )
        self.assertFalse(fl.match_model(self.CURSOR_HAY, "claude-fable-5", "cursor"))
        self.assertFalse(fl.match_model(self.CURSOR_HAY, "fable-5-high", "cursor"))
        self.assertFalse(fl.match_model(self.CURSOR_HAY, "typo-fable-5-high", "cursor"))

    AGY_HAY = """
gemini-3.7-flash-highGemini 3.7 Flash (High)
gemini-3.7-flash-lowGemini 3.7 Flash (Low)
gemini-3.1-pro-highGemini 3.1 Pro (High)
"""

    def test_agy_concatenated_id_name(self):
        self.assertTrue(
            fl.match_model(self.AGY_HAY, "gemini-3.7-flash-high", "agy")
        )
        self.assertTrue(fl.match_model(self.AGY_HAY, "gemini-3.7-flash-low", "agy"))
        self.assertFalse(fl.match_model(self.AGY_HAY, "gemini-3.7-flash", "agy"))
        self.assertFalse(fl.match_model(self.AGY_HAY, "gemini-3.5-flash-high", "agy"))


class StartArgsTests(unittest.TestCase):
    def test_pi_args(self):
        self.assertEqual(
            fl.start_native_args(
                "pi",
                "openai-codex/gpt-5.6-sol:xhigh",
                session_dir="/tmp/x/gpt",
                herdr_name="rev-gpt",
            ),
            [
                "--model",
                "openai-codex/gpt-5.6-sol:xhigh",
                "--session-dir",
                "/tmp/x/gpt",
                "--name",
                "rev-gpt",
            ],
        )

    def test_cursor_args_include_trust_force(self):
        self.assertEqual(
            fl.start_native_args(
                "cursor",
                "claude-fable-5-thinking-high",
                session_dir="/tmp/x/f",
                herdr_name="rev-fable5",
            ),
            [
                "--model",
                "claude-fable-5-thinking-high",
                "--trust",
                "--force",
            ],
        )

    def test_agy_args_skip_permissions(self):
        self.assertEqual(
            fl.start_native_args(
                "agy",
                "gemini-3.7-flash-high",
                session_dir="/tmp/x/g",
                herdr_name="rev-g37flash",
            ),
            [
                "--model",
                "gemini-3.7-flash-high",
                "--dangerously-skip-permissions",
            ],
        )


class ExpandNameTests(unittest.TestCase):
    def test_namespace(self):
        self.assertEqual(fl.expand_herdr_name("mixed-kind-rev", "fable5"), "mixed-kind-rev-fable5")
        self.assertTrue(fl.NAME_RE.match(fl.expand_herdr_name("r", "gpt56sol")))


if __name__ == "__main__":
    unittest.main()
