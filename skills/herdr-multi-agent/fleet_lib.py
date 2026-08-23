#!/usr/bin/env python3
"""Shared fleet parsing / preflight helpers for herdr-multi-agent launch.sh.

Keep kind:model rules and model-list matching in one place so launch heredocs
and unit tests cannot drift.
"""
from __future__ import annotations

import re
import shutil
import subprocess
from typing import Iterable

# Herdr agent kinds (from `herdr agent`). Unknown bare prefixes are NOT kinds.
KNOWN_KINDS = frozenset(
    {
        "pi",
        "claude",
        "codex",
        "gemini",
        "cursor",
        "devin",
        "agy",
        "cline",
        "omp",
        "mastracode",
        "opencode",
        "copilot",
        "kimi",
        "kiro",
        "droid",
        "amp",
        "grok",
        "hermes",
        "kilo",
        "qodercli",
        "maki",
    }
)

NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")


class FleetError(ValueError):
    """User-facing fleet/spec error (exit-worthy)."""


def sanitize_token(s: str, max_len: int = 32) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9_-]+", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    if not s:
        s = "agent"
    if not s[0].isalpha():
        s = "a" + s
    return s[:max_len]


def parse_kind_model(raw: str, default: str = "pi") -> tuple[str, str]:
    """Parse fleet RHS into (kind, model).

    Rules:
    - ``kind:model`` when ``kind`` is a bare known herdr kind → that kind.
    - Empty model after an explicit known kind → error.
    - Pi-style ``provider/model[:thinking]`` keeps default kind, but if the
      model contains ``/`` and default is non-pi, force kind=pi so global
      ``--kind cursor`` cannot mis-kind provider/model rows.
    - Unknown bare ``foo:bar`` is NOT treated as a kind (stays full model string).
    """
    default = (default or "pi").strip().lower() or "pi"
    if default not in KNOWN_KINDS:
        raise FleetError(f"unsupported default kind {default!r}")

    raw = (raw or "").strip()
    if not raw:
        return default, ""

    if ":" in raw:
        maybe_kind, maybe_model = raw.split(":", 1)
        if maybe_kind in KNOWN_KINDS and "/" not in maybe_kind:
            model = maybe_model.strip()
            if not model:
                raise FleetError(f"empty model after kind {maybe_kind!r}")
            return maybe_kind, model

    kind = default
    model = raw
    # provider/model ids are pi-shaped; do not let global --kind rebrand them.
    if "/" in model and kind != "pi":
        kind = "pi"
    return kind, model


def parse_agent_spec(spec: str, default_kind: str = "pi") -> tuple[str, str, str]:
    """Parse ``name=model`` / ``name=kind:model`` → (short, kind, model)."""
    if "=" not in spec:
        raise FleetError(f"invalid --agent (need name=model or name=kind:model): {spec!r}")
    short_raw, rest = spec.split("=", 1)
    short = sanitize_token(short_raw, 30)
    if not NAME_RE.match(short):
        raise FleetError(f"invalid agent short name {short!r} (want ^[a-z][a-z0-9_-]{{0,31}}$)")
    kind, model = parse_kind_model(rest, default_kind)
    if not model:
        raise FleetError(f"empty model for {short}")
    if kind not in KNOWN_KINDS:
        raise FleetError(f"unsupported agent kind {kind!r} for {short}")
    return short, kind, model


def agy_model_ids(hay: str) -> set[str]:
    """Extract model ids from `agy models` output.

    Lines are often ``idName`` with no separator, e.g.
    ``gemini-3.7-flash-highGemini 3.7 Flash (High)``.
    """
    ids: set[str] = set()
    for line in hay.splitlines():
        line = line.strip()
        if not line:
            continue
        m = re.match(r"^([a-z0-9][a-z0-9._-]*)", line)
        if m:
            ids.add(m.group(1).lower())
    return ids


def cursor_model_ids(hay: str) -> set[str]:
    """Extract model ids from `agent --list-models` style output."""
    ids: set[str] = set()
    for line in hay.splitlines():
        line = line.strip()
        if not line or line.lower().startswith("available models"):
            continue
        if " - " in line:
            token = line.split(" - ", 1)[0].strip()
        else:
            token = line.split()[0] if line.split() else ""
        if token:
            ids.add(token.lower())
    return ids


def match_model(hay: str, model: str, kind: str) -> bool:
    """Return True if model appears in a kind-specific --list-models dump."""
    m = (model or "").strip()
    if not m or not hay:
        return False
    kind = (kind or "pi").lower()
    hay_l = hay.lower()

    if kind == "pi":
        base = m.split(":", 1)[0]
        parts = base.split("/", 1)
        candidates = [base.lower()]
        if len(parts) == 2:
            candidates.append(parts[1].lower())
            # pi list lines often look like: provider/id or "id"
            candidates.append(parts[0].lower() + "/" + parts[1].lower())
        # Exact-ish: candidate must appear as a full token-ish substring on a line,
        # not a random mid-string hit for very short ids.
        for line in hay_l.splitlines():
            line = line.strip()
            if not line:
                continue
            for c in candidates:
                if not c:
                    continue
                if c == line or line.startswith(c + " ") or line.startswith(c + "\t"):
                    return True
                if f" {c} " in f" {line} ":
                    return True
                # provider/model on the line
                if c in line and ("/" in c or len(c) >= 8):
                    # require non-alnum boundary around match
                    if re.search(rf"(?<![a-z0-9_./-]){re.escape(c)}(?![a-z0-9_.-])", line):
                        return True
        return False

    if kind == "cursor":
        mid = m.lower()
        return mid in cursor_model_ids(hay)

    if kind == "agy":
        return m.lower() in agy_model_ids(hay)

    # Other kinds: exact line-prefix id match only (no bare substring).
    mid = m.lower()
    for line in hay_l.splitlines():
        line = line.strip()
        if not line:
            continue
        token = line.split(" - ", 1)[0].strip() if " - " in line else line.split()[0]
        if token == mid:
            return True
    return False


def load_cmd_output(cmd: list[str], timeout: float = 60.0) -> tuple[str | None, str | None]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except Exception as e:  # noqa: BLE001 — surface any spawn/timeout error
        return None, str(e)
    if p.returncode != 0 or not (p.stdout or "").strip():
        err = (p.stderr or p.stdout or "empty").strip().splitlines()
        return None, err[0] if err else f"rc={p.returncode}"
    return p.stdout, None


def which_cursor_cli() -> str | None:
    for cand in ("agent", "cursor-agent"):
        if shutil.which(cand):
            return cand
    return None


def preflight_specs(
    specs: Iterable[str],
    default_kind: str = "pi",
    *,
    hard_fail_missing_cli: bool = True,
) -> tuple[list[str], list[str]]:
    """Validate models for each kind.

    Returns (missing_entries, skipped_kinds).
    Raises FleetError when a required CLI is missing and hard_fail_missing_cli.
    """
    rows: list[tuple[str, str, str]] = []
    for spec in specs:
        if "=" not in spec:
            continue
        short, kind, model = parse_agent_spec(spec, default_kind)
        rows.append((short, kind, model))

    by_kind: dict[str, list[tuple[str, str]]] = {}
    for short, kind, model in rows:
        by_kind.setdefault(kind, []).append((short, model))

    missing: list[str] = []
    skipped: list[str] = []

    for kind, items in by_kind.items():
        if kind == "pi":
            if not shutil.which("pi"):
                if hard_fail_missing_cli:
                    raise FleetError(
                        f"pi not on PATH but fleet has {len(items)} pi agent(s); "
                        "install pi or remove those entries / pass --skip-model-preflight"
                    )
                skipped.append(kind)
                continue
            hay, err = load_cmd_output(["pi", "--list-models"])
            if hay is None:
                if hard_fail_missing_cli:
                    raise FleetError(f"pi --list-models failed ({err})")
                skipped.append(kind)
                continue
            for short, model in items:
                if not match_model(hay, model, "pi"):
                    missing.append(f"{short}=pi:{model} (pi --list-models)")
        elif kind == "cursor":
            bin_name = which_cursor_cli()
            if not bin_name:
                if hard_fail_missing_cli:
                    raise FleetError(
                        f"agent/cursor-agent not on PATH but fleet has {len(items)} cursor agent(s); "
                        "install cursor-cli or drop cursor entries / pass --skip-model-preflight"
                    )
                skipped.append(kind)
                continue
            hay, err = load_cmd_output([bin_name, "--list-models"])
            if hay is None:
                if hard_fail_missing_cli:
                    raise FleetError(f"{bin_name} --list-models failed ({err})")
                skipped.append(kind)
                continue
            for short, model in items:
                if not match_model(hay, model, "cursor"):
                    missing.append(f"{short}=cursor:{model} ({bin_name} --list-models)")
        elif kind == "agy":
            # Optional on GPU nodes: skip the seat instead of aborting the fleet.
            if not shutil.which("agy"):
                skipped.append(kind)
                continue
            hay, err = load_cmd_output(["agy", "models"])
            if hay is None:
                skipped.append(kind)
                continue
            for short, model in items:
                if not match_model(hay, model, "agy"):
                    missing.append(f"{short}=agy:{model} (agy models)")
        else:
            # No generic list-models contract for other kinds yet.
            skipped.append(kind)

    return missing, skipped


def start_native_args(kind: str, model: str, *, session_dir: str, herdr_name: str) -> list[str]:
    """Native argv after ``herdr agent start ... --`` for a kind."""
    kind = (kind or "pi").lower()
    if kind == "pi":
        return ["--model", model, "--session-dir", session_dir, "--name", herdr_name]
    if kind == "cursor":
        # --trust: workspace trust; --force: Run Everything (unattended shell/tools)
        return ["--model", model, "--trust", "--force"]
    if kind == "agy":
        return ["--model", model, "--dangerously-skip-permissions"]
    return ["--model", model]


def expand_herdr_name(prefix: str, short: str) -> str:
    short = sanitize_token(short, 30)
    prefix = sanitize_token(prefix, 32)
    budget = 32 - 1 - len(short)
    if budget >= 1:
        p = sanitize_token(prefix, budget)
        p = (p[:budget].rstrip("-") or "r")
        herdr_name = f"{p}-{short}"
    else:
        herdr_name = short[:32]
    herdr_name = herdr_name[:32]
    if not NAME_RE.match(herdr_name):
        raise FleetError(
            f"invalid herdr name derived: {herdr_name!r} "
            f"(need ^[a-z][a-z0-9_-]{{0,31}}$; shorten --label/--session-prefix)"
        )
    return herdr_name
