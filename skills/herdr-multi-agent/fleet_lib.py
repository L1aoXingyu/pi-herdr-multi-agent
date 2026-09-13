#!/usr/bin/env python3
"""Shared fleet parsing / preflight helpers for herdr-multi-agent launch.sh.

Keep kind:model rules and model-list matching in one place so launch heredocs
and unit tests cannot drift.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import socket
import subprocess
from pathlib import Path
from typing import Iterable

# Herdr agent kinds (from `herdr agent`) plus fleet-local `dsh`.
# `dsh` is not `herdr agent start --kind`; launch.sh pane-runs
# `dsh --profile dsh-tui`. The TUI reports `dsh-tui` (name often None).
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
        "qwen",
        "maki",
        "muse",
        "dsh",
    }
)
# Official DeepSeek API ids this key's /models returned (2026-09-10).
DSH_OFFICIAL_MODELS = frozenset({"deepseek-flash", "deepseek-v4-pro"})

NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
CODEX_REASONING_EFFORTS = frozenset(
    {"none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"}
)


def split_model_effort(model: str) -> tuple[str, str | None]:
    """Split ``id:effort`` when the suffix is a known Codex reasoning level."""
    raw = (model or "").strip()
    if ":" not in raw:
        return raw, None
    base, maybe = raw.rsplit(":", 1)
    effort = maybe.strip().lower()
    if effort in CODEX_REASONING_EFFORTS and base.strip():
        return base.strip(), effort
    return raw, None


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
    if not m:
        return False
    kind = (kind or "pi").lower()
    if kind == "dsh":
        return split_model_effort(m)[0] in DSH_OFFICIAL_MODELS
    if not hay:
        return False
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

    if kind == "codex":
        mid = split_model_effort(m)[0].lower()
        for line in hay_l.splitlines():
            line = line.strip()
            if not line:
                continue
            token = line.split(" - ", 1)[0].strip() if " - " in line else line.split()[0]
            if token == mid:
                return True
        return False

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


def load_cmd_output(
    cmd: list[str],
    timeout: float = 60.0,
    env: dict[str, str] | None = None,
) -> tuple[str | None, str | None]:
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, env=env
        )
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


def _uppercase_37890_env() -> dict[str, str]:
    """Same 37890 rule as launch pane-export, for parent-process --list-models."""
    env = os.environ.copy()
    if env.get("HTTPS_PROXY") or env.get("HTTP_PROXY") or env.get("ALL_PROXY"):
        return env
    s = socket.socket()
    s.settimeout(0.4)
    try:
        s.connect(("127.0.0.1", 37890))
    except OSError:
        return env
    finally:
        s.close()
    url = "http://127.0.0.1:37890"
    env["HTTPS_PROXY"] = env["HTTP_PROXY"] = env["ALL_PROXY"] = url
    return env


def which_cursor_cli() -> str | None:
    """Resolve cursor-cli. Same binary herdr starts: ``cursor-agent``.

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


def dsh_bin() -> str | None:
    return shutil.which("dsh")


def dsh_tui_profile_ok() -> bool:
    """True when ~/.dsh/profiles/dsh-tui has the TUI plugin."""
    path = Path.home() / ".dsh" / "profiles" / "dsh-tui" / "package.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    deps = data.get("dependencies") or {}
    bundles = ((data.get("dsh") or {}).get("profile") or {}).get("bundles") or []
    return (
        "@deepseek-harness-tui/dsh-tui" in deps
        or "@deepseek-harness-tui/dsh-tui" in bundles
    )


def dsh_credential_configured() -> bool:
    """True when official DeepSeek key is in the launch env or ~/.dsh credentials."""
    if (os.environ.get("DEEPSEEK_API_KEY") or "").strip():
        return True
    path = Path.home() / ".dsh" / ".credentials.yaml"
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return False
    for line in text.splitlines():
        if line.strip().startswith("DEEPSEEK_API_KEY:"):
            return bool(line.split(":", 1)[1].strip())
    return False


def write_dsh_home(home: Path, *, model: str) -> None:
    """Isolated DSH_HOME: settings for official model + symlink to user credentials."""
    home.mkdir(parents=True, exist_ok=True)
    model_id, effort = split_model_effort(model)
    effort = effort or "high"
    settings = (
        "# Fleet-isolated DeepSeek Harness settings. Credentials are a symlink.\n"
        "agent-default-model:\n"
        "  provider: deepseek-official\n"
        f"  model: {model_id}\n"
        f"  reasoningEffort: {effort}\n"
    )
    (home / "settings.yaml").write_text(settings, encoding="utf-8")
    dest = home / ".credentials.yaml"
    if dest.exists() or dest.is_symlink():
        dest.unlink()
    src = Path.home() / ".dsh" / ".credentials.yaml"
    if src.exists():
        dest.symlink_to(src)
        return
    key = (os.environ.get("DEEPSEEK_API_KEY") or "").strip()
    if not key:
        raise FleetError("dsh: no DEEPSEEK_API_KEY in env or ~/.dsh/.credentials.yaml")
    dest.write_text(f"version: 1\n\nrefs:\n  DEEPSEEK_API_KEY: {key}\n", encoding="utf-8")
    dest.chmod(0o600)


def write_dsh_runner(
    *,
    script_path: Path,
    home: Path,
    prompt_path: Path,
    stdout_path: Path,
    stderr_path: Path,
    pane_id: str,
    herdr_name: str,
    dsh_bin: str,
) -> None:
    """Write the pane-run script that reports working, runs headless dsh, then idle."""
    script_path.parent.mkdir(parents=True, exist_ok=True)
    dsh_dir = str(Path(dsh_bin).resolve().parent)
    body = f"""#!/usr/bin/env bash
set -u
export PATH={json.dumps(dsh_dir)}:"$PATH"
export DSH_HOME={json.dumps(str(home))}
export DSH_TELEMETRY_MODE=DISABLED
herdr pane report-agent {json.dumps(pane_id)} --source fleet-dsh --agent dsh --state working --seq 2 >/dev/null 2>&1 || true
python3 - <<'PY'
import pathlib, subprocess, sys
prompt = pathlib.Path({json.dumps(str(prompt_path))}).read_text()
out = open({json.dumps(str(stdout_path))}, "w")
err = open({json.dumps(str(stderr_path))}, "w")
r = subprocess.run(
    [{json.dumps(dsh_bin)}, "--profile", "headless", prompt],
    stdout=out,
    stderr=err,
)
sys.exit(r.returncode)
PY
rc=$?
herdr pane report-agent {json.dumps(pane_id)} --source fleet-dsh --agent dsh --state idle --seq 3 >/dev/null 2>&1 || true
exit "$rc"
"""
    script_path.write_text(body, encoding="utf-8")
    script_path.chmod(0o755)


def _codex_login_ok() -> tuple[bool, str]:
    """True when `codex login status` reports a session (stdout or stderr)."""
    try:
        p = subprocess.run(
            ["codex", "login", "status"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception as e:  # noqa: BLE001
        return False, str(e)
    text = ((p.stdout or "") + "\n" + (p.stderr or "")).strip()
    first = text.splitlines()[0] if text else f"rc={p.returncode}"
    if "logged in" in text.lower():
        return True, first
    return False, first


def _codex_models_cache_hay() -> str | None:
    """One slug per line from ``~/.codex/models_cache.json``, if present."""
    path = Path.home() / ".codex" / "models_cache.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    models = data.get("models") if isinstance(data, dict) else None
    if not isinstance(models, list):
        return None
    ids: list[str] = []
    for item in models:
        if not isinstance(item, dict):
            continue
        slug = item.get("slug") or item.get("id") or item.get("name")
        if slug:
            ids.append(str(slug))
    return "\n".join(ids) if ids else None


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
            hay, err = load_cmd_output(
                [bin_name, "--list-models"], env=_uppercase_37890_env()
            )
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
        elif kind == "codex":
            if not shutil.which("codex"):
                if hard_fail_missing_cli:
                    raise FleetError(
                        f"codex not on PATH but fleet has {len(items)} codex agent(s); "
                        "install Codex CLI, drop those entries, or pass --skip-model-preflight"
                    )
                skipped.append(kind)
                continue
            ok, detail = _codex_login_ok()
            if not ok:
                if hard_fail_missing_cli:
                    raise FleetError(
                        f"codex not logged in ({detail}); run `codex login` "
                        "or pass --skip-model-preflight"
                    )
                skipped.append(kind)
                continue
            cache_hay = _codex_models_cache_hay()
            if cache_hay:
                for short, model in items:
                    if not match_model(cache_hay, model, "codex"):
                        missing.append(
                            f"{short}=codex:{model} (~/.codex/models_cache.json)"
                        )
        elif kind == "dsh":
            if not dsh_bin():
                if hard_fail_missing_cli:
                    raise FleetError(
                        f"dsh not on PATH but fleet has {len(items)} dsh agent(s); "
                        "install @deepseek-ai/dsh, drop those entries, or pass "
                        "--skip-model-preflight"
                    )
                skipped.append(kind)
                continue
            if not dsh_credential_configured():
                if hard_fail_missing_cli:
                    raise FleetError(
                        "dsh seat needs DEEPSEEK_API_KEY in the environment or "
                        "~/.dsh/.credentials.yaml; or pass --skip-model-preflight"
                    )
                skipped.append(kind)
                continue
            if not dsh_tui_profile_ok():
                if hard_fail_missing_cli:
                    raise FleetError(
                        "dsh seat needs the dsh-tui profile "
                        "(dsh plugin --profile dsh-tui add @deepseek-harness-tui/dsh-tui); "
                        "or pass --skip-model-preflight"
                    )
                skipped.append(kind)
                continue
            for short, model in items:
                if not match_model("", model, "dsh"):
                    missing.append(
                        f"{short}=dsh:{model} (official ids: "
                        + ", ".join(sorted(DSH_OFFICIAL_MODELS))
                        + ")"
                    )
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
    if kind == "codex":
        model_id, effort = split_model_effort(model)
        args = ["--model", model_id]
        if effort:
            args.extend(["-c", f'model_reasoning_effort="{effort}"'])
        # TUI auto-update returns to a shell ("Please restart Codex") and herdr
        # reports agent_not_ready/blocked during that banner.
        args.extend(["-c", "check_for_update_on_startup=false"])
        # unattended: skip approval + hook-trust UIs (same blast radius as cursor --force)
        args.append("--dangerously-bypass-approvals-and-sandbox")
        args.append("--dangerously-bypass-hook-trust")
        return args
    if kind == "dsh":
        return []
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
        "cursor-agent-proxy",  # leftover titles from deleted wrapper
        "cursor-agent",
        "cursor",
        "cursor cli",
        "agent",
        "agy",
        "antigravity",
        "antigravity cli",
        "codex",
        "codex cli",
        "codex-cli",
        "openai codex",
    }
)
COLD_TITLE_HEADS = frozenset(
    {
        "codex",
        "cursor",
        "cursor-agent",
        "cursor-agent-proxy",
        "agent",
        "agy",
        "antigravity",
        "openai",
    }
)
PASTED_TEXT_RE = re.compile(r"\[\s*Pasted text #\d+", re.I)
PASTED_TEXT_BARE_RE = re.compile(r"\bPasted text #\d+", re.I)
PROMPT_HEAD_RE = re.compile(
    r"^(ROLE|ONLY|FORBIDDEN|READ-ONLY REVIEW|NO-WRITE REVIEW)\b", re.I
)
NONPI_MAX_TICKS = 30


def normalize_title(title: str | None) -> str:
    t = re.sub(r"\s+", " ", (title or "").strip())
    return t.lstrip("-–— ").strip()


def title_is_cold(title: str | None, *, cwd: str | None = None) -> bool:
    """True for CLI argv / default chrome / cwd-folder titles, not session names."""
    t = normalize_title(title).lower()
    if not t or t in COLD_TITLES:
        return True
    if t.startswith("openai codex"):
        return True
    head = t.split()[0]
    if head in COLD_TITLE_HEADS:
        return True
    if cwd:
        try:
            base = Path(cwd).resolve().name.lower()
        except OSError:
            base = Path(cwd).name.lower()
        if base and (t == base or t.endswith(" " + base) or t.endswith(" - " + base)):
            return True
    return False


def title_left_cold(title: str | None, *, cwd: str | None = None) -> bool:
    """True when the session title looks like a Cursor ROLE rename, not chrome."""
    t = normalize_title(title)
    return bool(t) and not title_is_cold(title, cwd=cwd)


def prompt_fingerprints(prompt_text: str | None) -> list[str]:
    """Distinctive lines that mean *this* fleet prompt landed.

    Prefer ROLE/ONLY/FORBIDDEN/READ-ONLY/NO-WRITE heads. Do not use VERDICT: — that
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
    kind: str | None = None,
    cwd: str | None = None,
) -> bool:
    """True if a full re-prompt would likely stack a duplicate brief.

    Cursor: session-title rename, Pasted text, or a fingerprint line.
    Codex: never trust the title (cwd / `codex --model …` look "renamed").
    Require pane paste marker or a prompt fingerprint.
    """
    kind = (kind or "").strip().lower()
    if kind != "codex" and title_left_cold(title, cwd=cwd):
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


DSH_ASSISTANT_MARKERS = ("⏺", "●")  # darwin ring, other platforms' solid dot
DSH_SPINNER_CHARS = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"


def herdr_row_for_dsh(
    agents: Iterable[dict],
    pane_id: str | None,
    herdr_name: str | None,
) -> dict | None:
    """Prefer pane_id: native dsh-tui reports often have name=None."""
    pane_id = (pane_id or "").strip()
    herdr_name = (herdr_name or "").strip()
    by_pane = None
    by_name = None
    for raw in agents or []:
        if not isinstance(raw, dict):
            continue
        if pane_id and str(raw.get("pane_id") or "") == pane_id:
            by_pane = raw
        if herdr_name and str(raw.get("name") or "") == herdr_name:
            by_name = raw
    return by_pane or by_name


def dsh_pane_is_done(blob: str | None) -> bool:
    """True when VERDICT: follows the last assistant marker (not the prompt echo)."""
    text = blob or ""
    last = -1
    for marker in DSH_ASSISTANT_MARKERS:
        idx = text.rfind(marker)
        if idx > last:
            last = idx
    if last < 0:
        return False
    return "VERDICT:" in text[last:]


def dsh_pane_looks_alive(blob: str | None) -> bool:
    """TUI chrome / spinner. Not a working signal when Herdr already has a row."""
    text = blob or ""
    if "dsh-TUI" in text or "deepseek-flash" in text or "❯" in text:
        return True
    return any(ch in text for ch in DSH_SPINNER_CHARS)


def dsh_runtime_status(
    *,
    agents: Iterable[dict] | None,
    list_ok: bool,
    pane_id: str | None,
    herdr_name: str | None,
    pane_blob: str | None,
    seen_working: bool,
) -> tuple[str, bool]:
    """Classify a dsh-TUI seat for the fleet watchdog.

    Herdr pane lifecycle wins (match pane_id, then name). Composer ``❯`` and
    the model footer are idle chrome — never "still working". Pre-turn idle
    (never seen working, no assistant trailer) stays ``working`` so a prompt
    echo of ``VERDICT:`` cannot finish the fleet. No Herdr row: pane fallback.
    """
    if not list_ok:
        return "unknown", seen_working
    row = herdr_row_for_dsh(agents or [], pane_id, herdr_name)
    pane_done = dsh_pane_is_done(pane_blob)
    if row is not None:
        st = str(row.get("agent_status") or "unknown").strip().lower() or "unknown"
        if st == "working":
            return "working", True
        if st == "done":
            return "done", True
        if st == "blocked":
            return "blocked", seen_working or pane_done
        if st == "idle":
            if seen_working or pane_done:
                return "idle", True
            return "working", False
        return st, seen_working
    if pane_done:
        return "done", True
    if dsh_pane_looks_alive(pane_blob):
        return "working", seen_working
    return "missing", seen_working
