#!/usr/bin/env bash
# Close a herdr-multi-agent review tab after main-agent synthesis.
# Honors outdir/policy.json auto_close and partial-failure guards unless --force.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: close.sh --outdir PATH [--force] [--reason TEXT]

Default: close the review tab recorded in outdir/tab_id.txt when policy allows.
Refuses when:
  - policy.auto_close is false (--keep / --no-close at launch), unless --force
  - results look partial (missing VERDICT) and --force not set
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

TAB_ID=""
if [[ -f "$OUTDIR/tab_id.txt" ]]; then
  TAB_ID=$(tr -d '[:space:]' <"$OUTDIR/tab_id.txt")
elif [[ -f "$OUTDIR/tab.json" ]]; then
  TAB_ID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["tab"]["tab_id"])' "$OUTDIR/tab.json")
fi
[[ -n "$TAB_ID" ]] || { echo "no tab_id in outdir" >&2; exit 2; }

python3 - <<'PY' "$OUTDIR" "$TAB_ID" "$FORCE" "$REASON"
import json, subprocess, sys
from pathlib import Path

outdir = Path(sys.argv[1])
tab_id = sys.argv[2]
force = sys.argv[3] == "1"
reason = sys.argv[4]

policy = {}
pf = outdir / "policy.json"
if pf.exists():
    policy = json.loads(pf.read_text())

auto_close = bool(policy.get("auto_close", True))
decision = {"tab_id": tab_id, "closed": False, "reason": reason, "auto_close": auto_close, "force": force}

# Partial / missing verdict guard
summary = outdir / "results" / "summary.txt"
agents_file = outdir / "agents.json"
names = []
if agents_file.exists():
    names = [a["name"] for a in json.loads(agents_file.read_text())]
missing = []
if names and summary.exists():
    text = summary.read_text(errors="ignore")
    # Count VERDICT blocks roughly; also check per-name section presence
    for n in names:
        # accept either a section header or any extract/pane with verdict
        pane = outdir / "results" / f"{n}.pane.txt"
        extract = outdir / "results" / f"{n}.extract.txt"
        blob = text
        for p in (pane, extract):
            if p.exists():
                blob += "\n" + p.read_text(errors="ignore")
        if "VERDICT:" not in blob:
            missing.append(n)
elif names:
    missing = list(names)

if not auto_close and not force:
    decision["reason"] = "auto_close_disabled"
    (outdir / "cleanup.json").write_text(json.dumps(decision, indent=2) + "\n")
    print(json.dumps(decision))
    raise SystemExit(0)

if missing and not force:
    decision["reason"] = "partial_or_missing_verdict"
    decision["missing"] = missing
    (outdir / "cleanup.json").write_text(json.dumps(decision, indent=2) + "\n")
    print(json.dumps(decision))
    raise SystemExit(0)

# Best-effort ctrl-c using namespaced herdr agent names
agents_path = outdir / "agents.json"
targets = []
if agents_path.exists():
    for r in json.loads(agents_path.read_text()):
        targets.append(r.get("herdr_name") or r.get("name"))
else:
    panes_map = outdir / "panes.map"
    if panes_map.exists():
        for line in panes_map.read_text().splitlines():
            if not line.strip():
                continue
            parts = line.split()
            # panes.map: short pane [herdr_name]
            targets.append(parts[2] if len(parts) >= 3 else parts[0])
for name in targets:
    if not name:
        continue
    subprocess.run(["herdr", "agent", "send-keys", name, "ctrl-c"], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

proc = subprocess.run(["herdr", "tab", "close", tab_id], check=False, capture_output=True, text=True)
decision["closed"] = proc.returncode == 0
decision["close_rc"] = proc.returncode
if proc.returncode != 0:
    decision["reason"] = f"tab_close_failed_rc_{proc.returncode}"
    decision["stderr"] = (proc.stderr or proc.stdout or "")[:500]
else:
    decision["reason"] = reason

(outdir / "cleanup.json").write_text(json.dumps(decision, indent=2) + "\n")
print(json.dumps(decision))
raise SystemExit(0 if decision["closed"] or decision["reason"] in {
    "auto_close_disabled", "partial_or_missing_verdict"
} else 1)
PY
