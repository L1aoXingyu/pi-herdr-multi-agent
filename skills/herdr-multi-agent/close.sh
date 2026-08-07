#!/usr/bin/env bash
# Close a herdr-multi-agent review tab after main-agent synthesis.
# Honors outdir/policy.json auto_close and strict partial-failure guards unless --force.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDICT_PY="$SKILL_DIR/verdict_lib.py"

usage() {
  cat <<'EOF'
Usage: close.sh --outdir PATH [--force] [--reason TEXT]

Default: close the review tab recorded in outdir/tab_id.txt when policy allows.
Refuses when:
  - policy.auto_close is false (--keep / --no-close at launch), unless --force
  - any non-start_failed agent lacks a *strict* VERDICT trailer, unless --force
  - zero startable agents produced verdicts, unless --force
Writes outdir/cleanup.json with the decision.
EOF
}

OUTDIR=""
FORCE=0
REASON="main_agent_synthesis_complete"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir) OUTDIR=${2:?}; shift 2 ;;
    --force) FORCE=1; shift ;;
    --reason) REASON=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$OUTDIR" && -d "$OUTDIR" ]] || { echo "need --outdir dir" >&2; exit 2; }
[[ -f "$VERDICT_PY" ]] || { echo "missing verdict_lib.py" >&2; exit 2; }

TAB_ID=""
if [[ -f "$OUTDIR/tab_id.txt" ]]; then
  TAB_ID=$(tr -d '[:space:]' <"$OUTDIR/tab_id.txt")
elif [[ -f "$OUTDIR/tab.json" ]]; then
  TAB_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["tab"]["tab_id"])' "$OUTDIR/tab.json")
fi
[[ -n "$TAB_ID" ]] || { echo "no tab_id in outdir" >&2; exit 2; }

python3 - <<'PY' "$OUTDIR" "$TAB_ID" "$FORCE" "$REASON" "$SKILL_DIR"
import json, subprocess, sys
from pathlib import Path

outdir = Path(sys.argv[1])
tab_id = sys.argv[2]
force = sys.argv[3] == "1"
reason = sys.argv[4]
skill_dir = Path(sys.argv[5])
sys.path.insert(0, str(skill_dir))
import verdict_lib as vl

policy = {}
pf = outdir / "policy.json"
if pf.exists():
    try:
        policy = json.loads(pf.read_text())
    except Exception:
        policy = {}

auto_close = bool(policy.get("auto_close", True))
marker = policy.get("verdict_marker") if isinstance(policy.get("verdict_marker"), str) else "VERDICT:"
decision = {
    "tab_id": tab_id,
    "closed": False,
    "reason": reason,
    "auto_close": auto_close,
    "force": force,
    "marker": marker,
}

agents = []
agents_file = outdir / "agents.json"
if agents_file.exists():
    agents = json.loads(agents_file.read_text())

missing = []
started = 0
for r in agents:
    if r.get("start_status") == "failed":
        continue
    started += 1
    short = r["name"]
    ok, _t = vl.agent_has_valid_verdict(outdir, short, marker=marker)
    if not ok:
        missing.append(short)

decision["started"] = started
decision["missing"] = missing

if not auto_close and not force:
    decision["reason"] = "auto_close_disabled"
    (outdir / "cleanup.json").write_text(json.dumps(decision, indent=2) + "\n")
    print(json.dumps(decision))
    raise SystemExit(0)

if (missing or started == 0) and not force:
    decision["reason"] = "partial_or_missing_verdict" if missing else "zero_startable_agents"
    (outdir / "cleanup.json").write_text(json.dumps(decision, indent=2) + "\n")
    print(json.dumps(decision))
    raise SystemExit(0)

# Best-effort soft-stop using namespaced herdr agent names from this run only
targets = []
for r in agents:
    targets.append(r.get("herdr_name") or r.get("name"))
for name in targets:
    if not name:
        continue
    subprocess.run(
        ["herdr", "agent", "send-keys", name, "ctrl-c"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

proc = subprocess.run(
    ["herdr", "tab", "close", tab_id],
    check=False,
    capture_output=True,
    text=True,
)
decision["closed"] = proc.returncode == 0
decision["close_rc"] = proc.returncode
if proc.returncode != 0:
    decision["reason"] = f"tab_close_failed_rc_{proc.returncode}"
    decision["stderr"] = (proc.stderr or proc.stdout or "")[:500]
else:
    decision["reason"] = reason

(outdir / "cleanup.json").write_text(json.dumps(decision, indent=2) + "\n")
print(json.dumps(decision))
raise SystemExit(
    0
    if decision["closed"]
    or decision["reason"]
    in {
        "auto_close_disabled",
        "partial_or_missing_verdict",
        "zero_startable_agents",
    }
    else 1
)
PY
