#!/usr/bin/env bash
# Name-based watchdog for herdr-multi-agent runs. Harvest VERDICT blocks; never close tabs.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDICT_PY="$SKILL_DIR/verdict_lib.py"

usage() {
  cat <<'EOF'
Usage: watchdog.sh --outdir PATH [--deadline-sec N] [--poll-sec N] [--verdict-marker STR]
                   [--stall-sec N]

Polls herdr agent list by herdr_name from outdir/agents.json until all are
idle|done|blocked|missing (start_failed skipped). It exits immediately once all
agents are terminal: success when every successful agent has a *strict* VERDICT
trailer, otherwise partial failure so bg_run can notify the parent promptly.
Explicit provider/model failures are classified from Pi session records.

Harvest order per agent:
  1) herdr agent read --source recent-unwrapped
  2) assistant-only session jsonl extract under outdir/<short>/
  3) herdr pane read fallback
  4) outdir/<short>/verdict.md recovery file

Writes:
  outdir/results/<short>.pane.txt
  outdir/results/<short>.extract.txt
  outdir/results/summary.txt
  outdir/results/progress.json

Exit 0 only if >=1 started agent and every non-failed agent has a valid trailer.
Exit 1 on partial/missing/zero-started. Does NOT close the review tab.
EOF
}

OUTDIR=""
DEADLINE_SEC=2400
POLL_SEC=20
STALL_SEC=600
MARKER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir) OUTDIR=${2:?}; shift 2 ;;
    --deadline-sec) DEADLINE_SEC=${2:?}; shift 2 ;;
    --poll-sec) POLL_SEC=${2:?}; shift 2 ;;
    --stall-sec) STALL_SEC=${2:?}; shift 2 ;;
    --verdict-marker) MARKER=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$OUTDIR" && -d "$OUTDIR" ]] || { echo "need --outdir" >&2; exit 2; }
[[ -f "$OUTDIR/agents.json" ]] || { echo "missing agents.json" >&2; exit 2; }
[[ -f "$VERDICT_PY" ]] || { echo "missing verdict_lib.py beside watchdog" >&2; exit 2; }
mkdir -p "$OUTDIR/results"
: >"$OUTDIR/results/summary.txt"

# Marker from flag or policy.json
if [[ -z "$MARKER" ]]; then
  MARKER=$(python3 -c 'import json,sys; from pathlib import Path
p=Path(sys.argv[1])/"policy.json"
m="VERDICT:"
if p.exists():
  try:
    v=json.loads(p.read_text()).get("verdict_marker")
    if isinstance(v,str) and v.strip(): m=v
  except Exception: pass
print(m)' "$OUTDIR")
fi

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

agent_status() {
  local herdr_name=$1 payload
  if ! payload=$(herdr agent list 2>/dev/null); then
    echo unknown
    return 0
  fi
  python3 -c 'import json,sys
d=json.loads(sys.stdin.read()); name=sys.argv[1]
for a in d["result"]["agents"]:
  if a.get("name")==name:
    print(a.get("agent_status","unknown")); raise SystemExit
print("missing")' "$herdr_name" <<<"$payload" 2>/dev/null || echo unknown
}

extract_session_assistant() {
  local short=$1 out=$2
  python3 -c '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import verdict_lib as vl
outdir, short, out = Path(sys.argv[2]), sys.argv[3], Path(sys.argv[4])
sess = vl.latest_session(outdir / short)
texts = vl.extract_assistant_texts(sess) if sess else []
out.write_text("\n".join(texts))
sys.exit(0 if texts else 1)
' "$SKILL_DIR" "$OUTDIR" "$short" "$out"
}

has_successful_outcome() {
  local short=$1 runtime_status=$2
  python3 -c 'import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import verdict_lib as vl
outcome = vl.agent_outcome(Path(sys.argv[2]), sys.argv[3], marker=sys.argv[4], runtime_status=sys.argv[5])
raise SystemExit(0 if outcome["status"] == "ok" else 1)
' "$SKILL_DIR" "$OUTDIR" "$short" "$MARKER" "$runtime_status" >/dev/null 2>&1
}

harvest_agent_text() {
  local herdr_name=$1 pane=$2 out=$3
  local tmp rc
  tmp=$(mktemp)
  set +e
  herdr agent read "$herdr_name" --source recent-unwrapped --lines 250 >"$tmp" 2>/dev/null
  rc=$?
  set -e
  if [[ $rc -eq 0 ]] && [[ -s "$tmp" ]]; then
    mv "$tmp" "$out"
    return 0
  fi
  if [[ -n "$pane" ]]; then
    set +e
    herdr pane read "$pane" --source recent-unwrapped --lines 250 >"$tmp" 2>/dev/null \
      || herdr pane read "$pane" --lines 250 >"$tmp" 2>/dev/null
    rc=$?
    set -e
    if [[ $rc -eq 0 ]] && [[ -s "$tmp" ]]; then
      mv "$tmp" "$out"
      return 0
    fi
  fi
  rm -f "$tmp"
  : >"$out"
  return 1
}

write_progress() {
  local line=$1 ready=$2
  python3 -c 'import json,sys,time
from pathlib import Path
statuses = dict(token.split("=", 1) for token in sys.argv[2].split())
Path(sys.argv[1]).write_text(json.dumps({
  "ts": time.time(),
  "status_line": sys.argv[2],
  "ready": sys.argv[3]=="1",
  "elapsed_sec": int(sys.argv[4]),
}, indent=2)+"\n")
Path(sys.argv[5]).write_text(json.dumps(statuses, indent=2)+"\n")' \
    "$OUTDIR/results/progress.json" "$line" "$ready" "$((SECONDS - START))" \
    "$OUTDIR/results/runtime-status.json"
}

# Load rows without mapfile (bash 3.2 portable)
ROWS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] && ROWS+=("$line")
done < <(python3 -c 'import json,sys
rows=json.load(open(sys.argv[1]))
for r in rows:
    name = r.get("name", "")
    herdr = r.get("herdr_name", name)
    pane = r.get("pane_id", "")
    st = r.get("start_status", "started")
    print("|".join([name, herdr, pane, st]))
' "$OUTDIR/agents.json")

if [[ ${#ROWS[@]} -eq 0 ]]; then
  log "FATAL: no agent rows parsed from agents.json"
  exit 1
fi

# Count startable agents
STARTABLE=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r short herdr_name pane start_status <<<"$row"
  if [[ "$start_status" != "failed" ]]; then
    STARTABLE=$((STARTABLE + 1))
  fi
done
if [[ "$STARTABLE" -eq 0 ]]; then
  log "FATAL: zero startable agents (all start_failed)"
  echo "ZERO_STARTABLE" | tee -a "$OUTDIR/results/summary.txt"
  exit 1
fi

log "watchdog start outdir=$OUTDIR deadline=${DEADLINE_SEC}s stall=${STALL_SEC}s n=${#ROWS[@]} startable=$STARTABLE marker=$MARKER"
START=$SECONDS
LAST_PROGRESS=$SECONDS
LAST_SIG=""

while true; do
  all_terminal=1
  blocked_count=0
  status_line=""
  STATUSES=()
  for row in "${ROWS[@]}"; do
    IFS='|' read -r short herdr_name pane start_status <<<"$row"
    if [[ "$start_status" == "failed" ]]; then
      STATUSES+=("start_failed")
      status_line+="$short=start_failed "
      continue
    fi
    st=$(agent_status "$herdr_name")
    STATUSES+=("$st")
    status_line+="$short=$st "
    if [[ "$st" == "blocked" ]]; then
      blocked_count=$((blocked_count + 1))
    elif [[ "$st" != "idle" && "$st" != "done" && "$st" != "missing" ]]; then
      all_terminal=0
    fi
  done
  log "$status_line"

  # progress signature for stall detection
  sig="$status_line"
  ready_now=0
  if [[ "$all_terminal" -eq 1 ]]; then
    ready=1
    missing_count=0
    status_idx=0
    for row in "${ROWS[@]}"; do
      IFS='|' read -r short herdr_name pane start_status <<<"$row"
      runtime_status=${STATUSES[$status_idx]}
      status_idx=$((status_idx + 1))
      if [[ "$start_status" == "failed" ]]; then
        continue
      fi
      harvest_agent_text "$herdr_name" "$pane" "$OUTDIR/results/${short}.pane.txt" || true
      extract_session_assistant "$short" "$OUTDIR/results/${short}.extract.txt" 2>/dev/null || true
      if ! has_successful_outcome "$short" "$runtime_status"; then
        ready=0
        missing_count=$((missing_count + 1))
      fi
    done
    if [[ "$ready" -eq 1 && "$blocked_count" -eq 0 ]]; then
      log "ALL_AGENTS_FINISHED_WITH_VERDICT"
      ready_now=1
      write_progress "$status_line" 1
      break
    fi
    # idle/done/blocked/missing are settled Herdr states. Waiting cannot create a
    # missing trailer and used to suppress bg_run completion notifications for up
    # to the full deadline. Exit partial now so the parent can retry/steer.
    log "ALL_AGENTS_TERMINAL_PARTIAL missing_verdict=$missing_count blocked=$blocked_count"
    write_progress "$status_line" 0
    break
  fi
  write_progress "$status_line" "$ready_now"

  if [[ "$sig" != "$LAST_SIG" ]]; then
    LAST_SIG="$sig"
    LAST_PROGRESS=$SECONDS
  elif (( SECONDS - LAST_PROGRESS >= STALL_SEC )); then
    log "STALL_REACHED no status/verdict progress for ${STALL_SEC}s — partial harvest"
    break
  fi

  if (( SECONDS - START >= DEADLINE_SEC )); then
    log "DEADLINE_REACHED"
    break
  fi
  sleep "$POLL_SEC"
done

# Final harvest into summary
for row in "${ROWS[@]}"; do
  IFS='|' read -r short herdr_name pane start_status <<<"$row"
  st="start_failed"
  if [[ "$start_status" != "failed" ]]; then
    st=$(agent_status "$herdr_name")
    if [[ "$all_terminal" -ne 1 ]]; then
      harvest_agent_text "$herdr_name" "$pane" "$OUTDIR/results/${short}.pane.txt" || true
    fi
  fi
  extract_session_assistant "$short" "$OUTDIR/results/${short}.extract.txt" 2>/dev/null || :
  {
    echo "===== $short ($herdr_name) status=$st ====="
    if [[ "$start_status" == "failed" ]]; then
      echo "START_FAILED"
    elif [[ "$st" == "blocked" ]]; then
      echo "BLOCKED_UI"
    fi
    python3 -c '
import json,sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import verdict_lib as vl
outdir, short, marker, st = Path(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
outcome = vl.agent_outcome(outdir, short, marker=marker, runtime_status=st)
if outcome["status"] == "ok":
    trailer = outcome.get("trailer") or {}
    print(trailer.get("raw") or json.dumps(trailer, indent=2))
elif outcome["status"] == "terminal_failure":
    failure = {k: v for k, v in outcome.items() if k != "status"}
    print("TERMINAL_FAILURE: " + json.dumps(failure, ensure_ascii=False))
else:
    print("NO_VALID_VERDICT")
    blob = vl.collect_agent_blob(outdir, short)
    print((blob or "")[-1500:])
' "$SKILL_DIR" "$OUTDIR" "$short" "$MARKER" "$st"
    echo
  } | tee -a "$OUTDIR/results/summary.txt" >/dev/null
done

log "watchdog done"
cat "$OUTDIR/results/summary.txt"

# Strict exit via verdict_lib. Preserve the structured result for the callback
# consumer even when the watchdog exits non-zero for a partial fleet.
set +e
python3 "$VERDICT_PY" check-outdir "$OUTDIR" "$MARKER" | tee "$OUTDIR/results/check.json"
rc=${PIPESTATUS[0]}
set -e
python3 -c 'import json,sys,time
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "ts": time.time(),
  "status": "ok" if sys.argv[2] == "0" else "partial",
  "exit_rc": int(sys.argv[2]),
}, indent=2) + "\n")' "$OUTDIR/watchdog_exit.json" "$rc"
if [[ $rc -ne 0 ]]; then
  log "WATCHDOG_PARTIAL_OR_MISSING"
  exit 1
fi
log "WATCHDOG_OK"
exit 0
