#!/usr/bin/env python3
"""Strict VERDICT trailer extraction for herdr-multi-agent.

Rejects prompt-template echoes and requires a nearby CONFIDENCE field when
possible. Used by watchdog.sh and close.sh.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Iterable

DEFAULT_MARKER = "VERDICT:"
CONF_RE = re.compile(r"\bCONFIDENCE:\s*(low|medium|high)\b", re.I)
TEMPLATE_HINTS = (
    "ship | ship-with-fixes | hold",
    "machine-harvested",
    "semicolon-separated",
    "<semicolon-separated",
    "end exactly with this trailer",
    "end with:",
    "required trailer shape",
)
FATAL_ERROR_PATTERNS = (
    ("rate_limit", re.compile(r"(?:\b429\b|usage limit|rate limit|quota|too many requests)", re.I)),
    ("auth", re.compile(r"(?:\b401\b|\b403\b|unauthori[sz]ed|forbidden|invalid api key|authentication)", re.I)),
    ("model_config", re.compile(r"(?:model (?:not found|does not exist|unavailable)|unknown model|invalid model)", re.I)),
)
PANE_FATAL_RE = re.compile(
    r"(?:Error:\s*(?:429|401|403|404)\b|GoUsageLimitError|usage limit reached|"
    r"rate limit exceeded|insufficient[_ ]quota|invalid api key|model not found)",
    re.I,
)


def _is_templatey(chunk: str) -> bool:
    low = chunk.lower()
    if any(h in low for h in TEMPLATE_HINTS):
        return True
    # Bare option lists and placeholder values are prompt echoes, not verdicts.
    first = chunk.splitlines()[0].strip() if chunk else ""
    first_value = first.split(":", 1)[-1].strip().lower()
    if "|" in first and "ship" in first.lower() and "hold" in first.lower():
        return True
    if first_value in {"", "...", "…", "tbd", "n/a", "na", "none", "placeholder"}:
        return True
    if not re.search(r"[\w\u4e00-\u9fff]", first_value):
        return True
    return False


def extract_trailer(blob: str, marker: str = DEFAULT_MARKER) -> dict | None:
    """Return best trailer dict from blob, or None."""
    if not blob or marker not in blob:
        return None
    idxs = [m.start() for m in re.finditer(re.escape(marker), blob)]
    best = None
    for i in reversed(idxs):
        chunk = blob[i : i + 2400]
        if _is_templatey(chunk):
            continue
        # field parse
        def field(name: str) -> str | None:
            m = re.search(
                rf"(?m)^{re.escape(name)}:\s*(.+?)(?=\n[A-Z][A-Z0-9_]+:|\n\n|\Z)",
                chunk,
            )
            if not m:
                return None
            return m.group(1).strip().split("\n")[0].strip()

        verdict = field("VERDICT")
        if verdict is None:
            # first line after marker
            line = chunk.split("\n", 1)[0]
            verdict = line.split(":", 1)[-1].strip()
        if not verdict or len(verdict) > 200:
            continue
        if _is_templatey(verdict):
            continue
        conf = field("CONFIDENCE")
        conf_m = CONF_RE.search(chunk)
        if conf is None and conf_m:
            conf = conf_m.group(1).lower()
        risks = field("RISKS")
        fixes = field("REQUIRED_FIXES")
        score = 0
        if conf:
            score += 3
        vlow = verdict.lower()
        if any(k in vlow for k in ("ship", "hold", "pass", "fail")):
            score += 2
        if risks is not None:
            score += 1
        if fixes is not None:
            score += 1
        # Prefer scored trailers; require at least ship/hold keyword OR confidence
        if score < 2:
            continue
        cand = {
            "verdict": verdict,
            "risks": risks or "",
            "required_fixes": fixes or "",
            "confidence": (conf or "").lower(),
            "raw": chunk[:1800],
            "score": score,
        }
        if best is None or cand["score"] > best["score"]:
            best = cand
        # first good from the end with conf is enough
        if conf:
            return cand
    return best


def extract_assistant_texts(session_path: Path) -> list[str]:
    """Pull assistant-looking text from a pi session jsonl."""
    texts: list[str] = []
    try:
        lines = session_path.read_text(errors="ignore").splitlines()
    except OSError:
        return texts
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        role = (obj.get("role") or obj.get("type") or "").lower()
        # common shapes: {role:assistant, content:..}, message events, etc.
        if role and role not in ("assistant", "model", "ai", "output", "message"):
            # still walk nested assistant content
            pass

        def walk(x, path_roles: tuple[str, ...] = ()):
            if isinstance(x, dict):
                r = (x.get("role") or x.get("type") or "")
                r = r.lower() if isinstance(r, str) else ""
                next_roles = path_roles + ((r,) if r else ())
                # record string bodies under assistant-ish nodes
                if any(rr in ("assistant", "model", "ai") for rr in next_roles):
                    for k in ("text", "content", "message"):
                        v = x.get(k)
                        if isinstance(v, str) and v.strip():
                            texts.append(v)
                        elif isinstance(v, list):
                            for item in v:
                                if isinstance(item, str) and item.strip():
                                    texts.append(item)
                                elif isinstance(item, dict):
                                    t = item.get("text") or item.get("content")
                                    if isinstance(t, str) and t.strip():
                                        texts.append(t)
                for v in x.values():
                    walk(v, next_roles)
            elif isinstance(x, list):
                for v in x:
                    walk(v, path_roles)

        walk(obj)
    return texts


def latest_session(dirpath: Path) -> Path | None:
    if not dirpath.is_dir():
        return None
    sess = sorted(dirpath.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    return sess[0] if sess else None


def _redact_error(message: str) -> str:
    """Keep summaries useful without copying account/workspace URLs into artifacts."""
    message = re.sub(r"https?://\S+", "<url>", message)
    message = re.sub(r"\bwrk_[A-Za-z0-9]+\b", "<workspace>", message)
    return " ".join(message.split())[:500]


def _classify_error(message: str) -> str:
    for category, pattern in FATAL_ERROR_PATTERNS:
        if pattern.search(message):
            return category
    return "provider_error"


def _session_terminal_error(session_path: Path) -> tuple[bool, str | None]:
    """Return whether a model turn exists and whether its latest turn ended in error."""
    saw_model_turn = False
    last_error: str | None = None
    try:
        lines = session_path.open(errors="ignore")
    except OSError:
        return False, None

    with lines:
        for line in lines:
            try:
                event = json.loads(line)
            except Exception:
                continue
            if not isinstance(event, dict):
                continue

            # Pi's common session shape is {type: "message", message: {role, ...}}.
            message = event.get("message")
            candidate = message if isinstance(message, dict) else event
            role = candidate.get("role")
            role = role.lower() if isinstance(role, str) else ""
            if role in ("assistant", "model", "ai"):
                saw_model_turn = True
                error_message = candidate.get("errorMessage")
                if isinstance(error_message, str) and error_message.strip():
                    last_error = error_message.strip()
                else:
                    # A later settled assistant turn supersedes an earlier transient error.
                    last_error = None
                continue

            # Support explicit top-level error events without scanning user prompt text.
            if event.get("type") == "error":
                event_message = event.get("errorMessage") or event.get("message")
                if isinstance(event_message, str) and event_message.strip():
                    last_error = event_message.strip()

    return saw_model_turn, last_error


def agent_terminal_failure(outdir: Path, short: str) -> dict | None:
    """Return an explicit settled-turn/provider failure, if one was recorded."""
    session = latest_session(outdir / short)
    if session:
        saw_model_turn, message = _session_terminal_error(session)
        if message:
            return {
                "category": _classify_error(message),
                "message": _redact_error(message),
                "source": "session",
            }
        if saw_model_turn:
            return None

    # Fallback only when no structured model turn is available. Require a strong signature so
    # prompt text containing words such as "error" or "quota" is not misclassified.
    pane = outdir / "results" / f"{short}.pane.txt"
    if pane.exists():
        blob = pane.read_text(errors="ignore")
        match = PANE_FATAL_RE.search(blob)
        if match:
            line_start = blob.rfind("\n", 0, match.start()) + 1
            line_end = blob.find("\n", match.end())
            if line_end < 0:
                line_end = min(len(blob), match.end() + 400)
            message = blob[line_start:line_end]
            return {
                "category": _classify_error(message),
                "message": _redact_error(message),
                "source": "pane",
            }
    return None


def collect_agent_blob(outdir: Path, short: str, prefer_assistant: bool = True) -> str:
    parts: list[str] = []
    # Prefer verdict.md (explicit recovery path)
    vmd = outdir / short / "verdict.md"
    if vmd.exists():
        parts.append(vmd.read_text(errors="ignore"))
    # Assistant-only session extract (avoids user prompt echo pollution)
    if prefer_assistant:
        sess = latest_session(outdir / short)
        if sess:
            asst = extract_assistant_texts(sess)
            if asst:
                parts.append("\n".join(asst))
    # Pane / full extract as weaker signals
    for p in (
        outdir / "results" / f"{short}.pane.txt",
        outdir / "results" / f"{short}.extract.txt",
    ):
        if p.exists():
            parts.append(p.read_text(errors="ignore"))
    return "\n".join(parts)


def agent_has_valid_verdict(
    outdir: Path,
    short: str,
    marker: str = DEFAULT_MARKER,
    start_status: str | None = None,
) -> tuple[bool, dict | None]:
    if start_status == "failed":
        return False, None
    blob = collect_agent_blob(outdir, short)
    trailer = extract_trailer(blob, marker=marker)
    return (trailer is not None, trailer)


def agent_outcome(
    outdir: Path,
    short: str,
    marker: str = DEFAULT_MARKER,
    start_status: str | None = None,
    runtime_status: str | None = None,
) -> dict:
    """Resolve outcome precedence once for reporting and strict fleet checks."""
    if start_status == "failed":
        return {"status": "start_failed"}
    if runtime_status == "blocked":
        return {"status": "blocked"}
    if runtime_status not in (None, "idle", "done", "missing"):
        return {"status": "not_terminal", "agent_status": runtime_status}
    # A latest-turn error supersedes verdict text left by an older successful turn.
    failure = agent_terminal_failure(outdir, short)
    if failure:
        return {"status": "terminal_failure", **failure}
    ok, trailer = agent_has_valid_verdict(outdir, short, marker=marker)
    if ok:
        return {"status": "ok", "trailer": trailer}
    if runtime_status == "missing":
        return {"status": "agent_missing"}
    return {"status": "missing_verdict"}


def load_marker(outdir: Path, fallback: str = DEFAULT_MARKER) -> str:
    pf = outdir / "policy.json"
    if pf.exists():
        try:
            m = json.loads(pf.read_text()).get("verdict_marker")
            if isinstance(m, str) and m.strip():
                return m
        except Exception:
            pass
    return fallback


def main(argv: list[str]) -> int:
    """CLI:
      verdict_lib.py extract <file> [marker]
      verdict_lib.py check-outdir <outdir> [marker]
      verdict_lib.py has <outdir> <short> [marker]
      verdict_lib.py failure <outdir> <short>
    """
    if len(argv) < 2:
        print("usage: extract|check-outdir|has ...", file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "extract":
        path = Path(argv[2])
        marker = argv[3] if len(argv) > 3 else DEFAULT_MARKER
        blob = path.read_text(errors="ignore")
        t = extract_trailer(blob, marker)
        if not t:
            print("NO_VERDICT")
            return 1
        print(json.dumps(t, indent=2))
        return 0
    if cmd == "has":
        outdir = Path(argv[2])
        short = argv[3]
        marker = argv[4] if len(argv) > 4 else load_marker(outdir)
        ok, t = agent_has_valid_verdict(outdir, short, marker=marker)
        print("yes" if ok else "no")
        if t:
            print(json.dumps(t))
        return 0 if ok else 1
    if cmd == "failure":
        outdir = Path(argv[2])
        short = argv[3]
        failure = agent_terminal_failure(outdir, short)
        if not failure:
            print("NO_TERMINAL_FAILURE")
            return 1
        print(json.dumps(failure, indent=2))
        return 0
    if cmd == "check-outdir":
        outdir = Path(argv[2])
        marker = argv[3] if len(argv) > 3 else load_marker(outdir)
        agents = json.loads((outdir / "agents.json").read_text())
        runtime_statuses = {}
        runtime_file = outdir / "results" / "runtime-status.json"
        if runtime_file.exists():
            try:
                runtime_statuses = json.loads(runtime_file.read_text())
            except Exception:
                runtime_statuses = {}
        missing = []
        started = 0
        ok_n = 0
        details = []
        for r in agents:
            short = r["name"]
            st = r.get("start_status", "started")
            outcome = agent_outcome(
                outdir,
                short,
                marker=marker,
                start_status=st,
                runtime_status=runtime_statuses.get(short),
            )
            status = outcome["status"]
            if status == "start_failed":
                details.append({"name": short, "status": status})
                continue
            started += 1
            if status == "ok":
                ok_n += 1
                details.append(
                    {"name": short, "status": status, "verdict": (outcome.get("trailer") or {}).get("verdict")}
                )
            else:
                missing.append(short)
                details.append({"name": short, **{k: v for k, v in outcome.items() if k != "trailer"}})
        result = {
            "started": started,
            "ok": ok_n,
            "missing": missing,
            "details": details,
        }
        print(json.dumps(result, indent=2))
        if started == 0:
            return 1
        if missing:
            return 1
        return 0
    print(f"unknown cmd: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
