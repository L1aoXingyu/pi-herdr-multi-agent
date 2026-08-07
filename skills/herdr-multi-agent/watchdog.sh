#!/usr/bin/env bash
# Name-based watchdog for herdr-multi-agent runs. Harvest VERDICT blocks; never close tabs.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: watchdog.sh --outdir PATH [--deadline-sec N] [--poll-sec N] [--verdict-marker STR]

Polls herdr agent list by herdr_name from outdir/agents.json until all are
idle|done|blocked (or missing after start failure) AND each successful agent
has VERDICT: in agent-read/session extract (or deadline).

Harvest order per agent:
  1) herdr agent read --source recent-unwrapped
  2) session jsonl extract under outdir/<short>/
  3) herdr pane read fallback

Writes:
  outdir/results/<short>.pane.txt
  outdir/results/<short>.extract.txt
  outdir/results/summary.txt

Does NOT close the review tab (main agent runs close.sh after synthesis).
Treats idle and done as terminal; unknown is NOT complete; blocked is
terminal-ish but may lack VERDICT.
EOF
}

OUTDIR=""
DEADLINE_SEC=2400
POLL_SEC=20
MARKER="VERDICT:"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir) OUTDIR=${2:?}; shift 2 ;;
    --deadline-sec) DEADLINE_SEC=${2:?}; shift 2 ;;
    --poll-sec) POLL_SEC=${2:?}; shift 2 ;;
    --verdict-marker) MARKER=${2:?}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$OUTDIR" && -d "$OUTDIR" ]] || { echo "need --outdir" >&2; exit 2; }
[[ -f "$OUTDIR/agents.json" ]] || { echo "missing agents.json" >&2; exit 2; }
mkdir -p "$OUTDIR/results"
: >"$OUTDIR/results/summary.txt"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

agent_status() {
  local herdr_name=$1
  herdr agent list 2>/dev/null | python3 -c 'import json,sys
d=json.loads(sys.stdin.read()); name=sys.argv[1]
for a in d["result"]["agents"]:
  if a.get("name")==name:
    print(a.get("agent_status","missing")); raise SystemExit
print("missing")' "$herdr_name" 2>/dev/null || echo missing
}

extract_session() {
  local short=$1 out=$2
  local sess
  sess=$(ls -t "$OUTDIR/$short"/*.jsonl 2>/dev/null | head -1 || true)
  [[ -n "$sess" ]] || return 1
  python3 - "$sess" "$out" <<'PY'
import json,sys
path,out=sys.argv[1],sys.argv[2]
texts=[]
with open(path) as f:
  for line in f:
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except Exception: continue
    def walk(x):
      if isinstance(x,dict):
        for k,v in x.items():
          if k in ("text","content","message") and isinstance(v,str): texts.append(v)
          else: walk(v)
      elif isinstance(x,list):
        for v in x: walk(v)
    walk(o)
open(out,"w").write("\n".join(texts))
PY
}

has_verdict() {
  local short=$1
  local pane="$OUTDIR/results/${short}.pane.txt"
  local extract="$OUTDIR/results/${short}.extract.txt"
  local file_fallback="$OUTDIR/${short}/verdict.md"
  if [[ -f "$pane" ]] && grep -q "$MARKER" "$pane" 2>/dev/null; then return 0; fi
  if [[ -f "$extract" ]] && grep -q "$MARKER" "$extract" 2>/dev/null; then return 0; fi
  if [[ -f "$file_fallback" ]] && grep -q "$MARKER" "$file_fallback" 2>/dev/null; then return 0; fi
  return 1
}

harvest_agent_text() {
  # Prefer official agent read surface; fall back to pane read.
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

mapfile -t ROWS < <(python3 -c 'import json,sys
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

log "watchdog start outdir=$OUTDIR deadline=${DEADLINE_SEC}s n=${#ROWS[@]}"
START=$SECONDS

while true; do
  all_terminal=1
  status_line=""
  for row in "${ROWS[@]}"; do
    IFS='|' read -r short herdr_name pane start_status <<<"$row"
    if [[ "$start_status" == "failed" ]]; then
      status_line+="$short=start_failed "
      continue
    fi
    st=$(agent_status "$herdr_name")
    status_line+="$short=$st "
    # unknown is NOT terminal (official: present but unclassified).
    if [[ "$st" != "idle" && "$st" != "done" && "$st" != "blocked" && "$st" != "missing" ]]; then
      all_terminal=0
    fi
  done
  log "$status_line"

  if [[ "$all_terminal" -eq 1 ]]; then
    ready=1
    for row in "${ROWS[@]}"; do
      IFS='|' read -r short herdr_name pane start_status <<<"$row"
      if [[ "$start_status" == "failed" ]]; then
        continue
      fi
      harvest_agent_text "$herdr_name" "$pane" "$OUTDIR/results/${short}.pane.txt" || true
      extract_session "$short" "$OUTDIR/results/${short}.extract.txt" 2>/dev/null || true
      # Include file-fallback verdict.md into extract side-channel if present.
      if [[ -f "$OUTDIR/${short}/verdict.md" ]]; then
        cat "$OUTDIR/${short}/verdict.md" >>"$OUTDIR/results/${short}.extract.txt" 2>/dev/null || true
      fi
      if ! has_verdict "$short"; then
        ready=0
      fi
    done
    if [[ "$ready" -eq 1 ]]; then
      log "ALL_AGENTS_FINISHED_WITH_VERDICT"
      break
    fi
    log "terminal but missing $MARKER; continuing wait"
  fi

  if (( SECONDS - START >= DEADLINE_SEC )); then
    log "DEADLINE_REACHED"
    break
  fi
  sleep "$POLL_SEC"
done

# Final harvest
for row in "${ROWS[@]}"; do
  IFS='|' read -r short herdr_name pane start_status <<<"$row"
  st="start_failed"
  if [[ "$start_status" != "failed" ]]; then
    st=$(agent_status "$herdr_name")
    harvest_agent_text "$herdr_name" "$pane" "$OUTDIR/results/${short}.pane.txt" || true
  fi
  extract_session "$short" "$OUTDIR/results/${short}.extract.txt" 2>/dev/null || true
  if [[ -f "$OUTDIR/${short}/verdict.md" ]]; then
    {
      echo
      echo "----- verdict.md -----"
      cat "$OUTDIR/${short}/verdict.md"
    } >>"$OUTDIR/results/${short}.extract.txt" 2>/dev/null || true
  fi
  {
    echo "===== $short ($herdr_name) status=$st ====="
    if [[ "$start_status" == "failed" ]]; then
      echo "START_FAILED"
    elif [[ "$st" == "blocked" ]]; then
      echo "BLOCKED_UI"
      python3 - "$OUTDIR/results/${short}.pane.txt" "$OUTDIR/results/${short}.extract.txt" "$MARKER" <<'PY'
import sys
marker=sys.argv[3]
blobs=[]
for p in sys.argv[1:3]:
  try: blobs.append(open(p, errors="ignore").read())
  except Exception: pass
blob="\n".join(blobs)
idx=blob.rfind(marker)
if idx<0:
  print("NO_VERDICT_FOUND (blocked)")
  print((blobs[0] if blobs else "")[-1500:])
else:
  print(blob[idx:idx+1800])
PY
    else
      python3 - "$OUTDIR/results/${short}.pane.txt" "$OUTDIR/results/${short}.extract.txt" "$MARKER" <<'PY'
import sys
marker=sys.argv[3]
blobs=[]
for p in sys.argv[1:3]:
  try: blobs.append(open(p, errors="ignore").read())
  except Exception: pass
blob="\n".join(blobs)
idx=blob.rfind(marker)
if idx<0:
  print("NO_VERDICT_FOUND")
  print((blobs[0] if blobs else "")[-1500:])
else:
  print(blob[idx:idx+1800])
PY
    fi
    echo
  } | tee -a "$OUTDIR/results/summary.txt" >/dev/null
done

log "watchdog done"
cat "$OUTDIR/results/summary.txt"

# exit 0 if every non-failed agent has verdict; else 1
python3 - <<PY
import sys
from pathlib import Path
import json
outdir = Path("$OUTDIR")
marker = "$MARKER"
agents = json.loads((outdir / "agents.json").read_text())
missing = []
for r in agents:
    if r.get("start_status") == "failed":
        continue
    short = r["name"]
    blob = ""
    for p in (
        outdir / "results" / f"{short}.pane.txt",
        outdir / "results" / f"{short}.extract.txt",
        outdir / short / "verdict.md",
    ):
        if p.exists():
            blob += p.read_text(errors="ignore")
    if marker not in blob:
        missing.append(short)
if missing:
    print("MISSING_VERDICT", ",".join(missing))
    sys.exit(1)
print("OK")
PY
