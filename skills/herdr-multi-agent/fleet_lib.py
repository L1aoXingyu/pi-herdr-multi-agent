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
        # Stop before TitleCase name or whitespace. Do not IGNORECASE — G would
        # be eaten as part of the id.
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


def looks_like_cursor_cli_help(text: str) -> bool:
    """True if --help output is cursor-cli, not Grok Build or another `agent`."""
    low = (text or "").lower()
    if "grok build" in low:
        return False
    return "--list-models" in low or "cursor agent" in low


def which_cursor_cli() -> str | None:
    """Resolve cursor-cli. Prefer the unambiguous binary.

    Bare ``agent`` is also Grok Build (``~/.grok/bin/agent``) on some PATHs.
    Only accept ``agent`` when ``--help`` looks like cursor-cli.
    """
    for cand in ("cursor-agent", "agent"):
        path = shutil.which(cand)
        if not path:
            continue
        hay, _err = load_cmd_output([path, "--help"], timeout=15.0)
        if hay is not None and looks_like_cursor_cli_help(hay):
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
                        f"cursor-cli not found but fleet has {len(items)} cursor agent(s); "
                        "install cursor-agent (do not use Grok's `agent`), drop cursor entries, "
                        "or pass --skip-model-preflight"
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


# --- non-pi prompt landing (cursor composer) ---
#
# herdr `idle` after `agent prompt` does NOT mean the composer is empty.
# Cursor often ACKs, renames the session from ROLE:, and still stays idle
# under --no-focus. A second full paste stacks duplicate briefs.

COLD_TITLES = frozenset(
    {
        "",
        "cursor agent",
        "cursor-agent",
        "cursor",
        "cursor cli",
        "agent",
        "agy",
        "antigravity",
        "antigravity cli",
    }
)
PASTED_TEXT_RE = re.compile(r"\[\s*Pasted text #\d+", re.I)
PASTED_TEXT_BARE_RE = re.compile(r"\bPasted text #\d+", re.I)
PROMPT_HEAD_RE = re.compile(r"^(ROLE|ONLY|FORBIDDEN|READ-ONLY REVIEW)\b", re.I)
NONPI_MAX_TICKS = 30


def normalize_title(title: str | None) -> str:
    t = re.sub(r"\s+", " ", (title or "").strip())
    return t.lstrip("-–— ").strip()


def title_left_cold(title: str | None) -> bool:
    """True when the session title is no longer a cursor cold-start default."""
    t = normalize_title(title).lower()
    return bool(t) and t not in COLD_TITLES


def prompt_fingerprints(prompt_text: str | None) -> list[str]:
    """Distinctive lines that mean *this* fleet prompt landed.

    Prefer ROLE/ONLY/FORBIDDEN/READ-ONLY heads. Do not use VERDICT: — that
    string lives in the template and in the agent's reply.
    """
    fps: list[str] = []
    for line in (prompt_text or "").splitlines():
        s = line.strip()
        if PROMPT_HEAD_RE.match(s) and len(s) >= 12:
            fps.append(s)
    if fps:
        return fps
    for line in (prompt_text or "").splitlines():
        s = line.strip()
        if len(s) >= 32 and not s.upper().startswith("VERDICT"):
            return [s]
    return []


def prompt_already_landed(
    *,
    title: str | None = None,
    pane_text: str | None = None,
    prompt_text: str | None = None,
) -> bool:
    """True if a full re-prompt would likely stack a duplicate brief.

    Any one signal is enough: title left the cold default, Cursor paste
    marker, or a fingerprint line from the prompt file in the pane.
    """
    if title_left_cold(title):
        return True
    pane = pane_text or ""
    if PASTED_TEXT_RE.search(pane) or PASTED_TEXT_BARE_RE.search(pane):
        return True
    if pane:
        for fp in prompt_fingerprints(prompt_text):
            if fp in pane:
                return True
    return False


def nonpi_prompt_policy(
    *,
    idle_ticks: int,
    landed: bool,
    max_ticks: int = NONPI_MAX_TICKS,
) -> str:
    """Next action for a non-pi agent that is still not ``working``.

    Returns one of: ``wait``, ``enter``, ``repaste``, ``skip_repaste``,
    ``accept``, ``fail``.

    Enter once (~6s) so a sitting composer can submit. Full re-paste only
    when the composer still looks empty. Landed+idle after that enter is
    success — watchdog owns the wait.
    """
    if idle_ticks < 1:
        raise ValueError(f"idle_ticks must be >= 1, got {idle_ticks}")
    if idle_ticks == 3:
        return "enter"
    if idle_ticks == 6:
        return "skip_repaste" if landed else "repaste"
    if landed and idle_ticks >= 4:
        return "accept"
    if idle_ticks >= max_ticks:
        return "accept" if landed else "fail"
    return "wait"
