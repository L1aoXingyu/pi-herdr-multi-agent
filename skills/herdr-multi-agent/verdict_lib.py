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


def _is_templatey(chunk: str) -> bool:
    low = chunk.lower()
    if any(h in low for h in TEMPLATE_HINTS):
        return True
    # bare option list in the verdict value
    first = chunk.splitlines()[0] if chunk else ""
    if "|" in first and "ship" in first.lower() and "hold" in first.lower():
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
    if cmd == "check-outdir":
        outdir = Path(argv[2])
        marker = argv[3] if len(argv) > 3 else load_marker(outdir)
        agents = json.loads((outdir / "agents.json").read_text())
        missing = []
        started = 0
        ok_n = 0
        details = []
        for r in agents:
            short = r["name"]
            st = r.get("start_status", "started")
            if st == "failed":
                details.append({"name": short, "status": "start_failed"})
                continue
            started += 1
            ok, t = agent_has_valid_verdict(outdir, short, marker=marker, start_status=st)
            if ok:
                ok_n += 1
                details.append({"name": short, "status": "ok", "verdict": (t or {}).get("verdict")})
            else:
                missing.append(short)
                details.append({"name": short, "status": "missing_verdict"})
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
