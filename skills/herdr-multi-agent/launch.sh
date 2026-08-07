#!/usr/bin/env bash
# Launch N interactive Pi agents in a Herdr tab, prompt them, write mapping files.
# Does NOT run the watchdog (use watchdog.sh via bg_run).
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_FLEET_FILE="$SKILL_DIR/fleet.defaults"

usage() {
  cat <<'EOF'
Usage: launch.sh --label NAME --cwd PATH --outdir PATH --prompt-file PATH \
  [--agent name=provider/model[:thinking] ...]
  [--fleet-file PATH]
  [--workspace ID] [--session-prefix STR] [--start-timeout-ms N] [--ready-retries N]
  [--keep|--no-close] [--force]

Creates a Herdr tab, splits panes, starts Pi serially with shell-ready retries,
prompts every agent, writes mapping + policy under outdir.

If no --agent is given, loads name=model lines from --fleet-file (default:
$SKILL_DIR/fleet.defaults). Edit that file or pass --agent / --fleet-file to
override. Models must already exist in the caller's pi config.
Herdr agent names are namespaced as <session-prefix>-<short-name> to avoid collisions.
--keep / --no-close => policy.auto_close=false.
--force allows reusing a non-empty outdir.
EOF
}

LABEL=""
CWD=""
OUTDIR=""
PROMPT_FILE=""
WORKSPACE=""
SESSION_PREFIX=""
FLEET_FILE=""
START_TIMEOUT_MS=180000
READY_RETRIES=12
AUTO_CLOSE=1
FORCE=0
AGENTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL=${2:?}; shift 2 ;;
    --cwd) CWD=${2:?}; shift 2 ;;
    --outdir) OUTDIR=${2:?}; shift 2 ;;
    --prompt-file) PROMPT_FILE=${2:?}; shift 2 ;;
    --workspace) WORKSPACE=${2:?}; shift 2 ;;
    --session-prefix) SESSION_PREFIX=${2:?}; shift 2 ;;
    --fleet-file) FLEET_FILE=${2:?}; shift 2 ;;
    --start-timeout-ms) START_TIMEOUT_MS=${2:?}; shift 2 ;;
    --ready-retries) READY_RETRIES=${2:?}; shift 2 ;;
    --agent) AGENTS+=("${2:?}"); shift 2 ;;
    --keep|--no-close) AUTO_CLOSE=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$LABEL" && -n "$CWD" && -n "$OUTDIR" && -n "$PROMPT_FILE" ]] || {
  echo "missing required args" >&2; usage >&2; exit 2
}
[[ -d "$CWD" ]] || { echo "cwd not a directory: $CWD" >&2; exit 2; }
[[ -f "$PROMPT_FILE" ]] || { echo "prompt file missing: $PROMPT_FILE" >&2; exit 2; }

# Clamp herdr max start timeout (CLI max 300000).
if [[ "$START_TIMEOUT_MS" =~ ^[0-9]+$ ]]; then
  if (( START_TIMEOUT_MS > 300000 )); then START_TIMEOUT_MS=300000; fi
  if (( START_TIMEOUT_MS < 1000 )); then START_TIMEOUT_MS=1000; fi
else
  echo "invalid --start-timeout-ms" >&2; exit 2
fi
if ! [[ "$READY_RETRIES" =~ ^[0-9]+$ ]] || (( READY_RETRIES < 1 )); then
  echo "invalid --ready-retries" >&2; exit 2
fi

# Default fleet when caller omits --agent: load name=model lines from fleet file.
load_fleet_file() {
  local path=$1 line name model
  [[ -f "$path" ]] || { echo "fleet file missing: $path" >&2; exit 2; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip comments / blanks
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue
    if [[ "$line" != *=* ]]; then
      echo "invalid fleet line (need name=model): $line" >&2
      exit 2
    fi
    AGENTS+=("$line")
  done <"$path"
  if [[ ${#AGENTS[@]} -eq 0 ]]; then
    echo "fleet file empty: $path" >&2
    exit 2
  fi
}

if [[ ${#AGENTS[@]} -eq 0 ]]; then
  FLEET_FILE=${FLEET_FILE:-$DEFAULT_FLEET_FILE}
  load_fleet_file "$FLEET_FILE"
elif [[ -n "$FLEET_FILE" ]]; then
  echo "ignore --fleet-file because --agent was also provided" >&2
fi

SESSION_PREFIX=${SESSION_PREFIX:-$LABEL}
# sanitize prefix for herdr names
SESSION_PREFIX=$(printf '%s' "$SESSION_PREFIX" | tr -c 'a-zA-Z0-9_-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
[[ -n "$SESSION_PREFIX" ]] || SESSION_PREFIX="review"

if [[ -e "$OUTDIR/agents.json" && "$FORCE" -ne 1 ]]; then
  echo "outdir already has agents.json: $OUTDIR (pass --force to reuse)" >&2
  exit 2
fi
mkdir -p "$OUTDIR"
LOG="$OUTDIR/launch.log"
exec > >(tee -a "$LOG") 2>&1

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

json_get() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); '"$2"'' "$1"
}

pick_workspace() {
  if [[ -n "$WORKSPACE" ]]; then
    echo "$WORKSPACE"
    return
  fi
  herdr workspace list | python3 -c '
import json,sys
d=json.loads(sys.stdin.read())
ws=d.get("result",d).get("workspaces",[])
for w in ws:
  if w.get("focused"):
    print(w["workspace_id"]); raise SystemExit
if not ws:
    raise SystemExit("no herdr workspaces")
print(ws[0]["workspace_id"])
'
}

validate_and_expand_agents() {
  python3 - <<'PY' "$SESSION_PREFIX" "${AGENTS[@]}"
import json, re, subprocess, sys
prefix = sys.argv[1]
specs = sys.argv[2:]
# herdr 0.7.x live names: ^[a-z][a-z0-9_-]{0,31}$  (letter start, max 32)
name_re = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")

def sanitize_token(s: str) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9_-]+", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    if not s:
        s = "agent"
    if not s[0].isalpha():
        s = "a" + s
    return s[:32]

prefix = sanitize_token(prefix)
rows = []
shorts = set()
for spec in specs:
    if "=" not in spec:
        raise SystemExit(f"invalid --agent (need name=model): {spec!r}")
    short, model = spec.split("=", 1)
    short = sanitize_token(short)
    if not name_re.match(short):
        raise SystemExit(f"invalid agent short name {short!r} (want ^[a-z][a-z0-9_-]{{0,31}}$)")
    if not model.strip():
        raise SystemExit(f"empty model for {short}")
    if short in shorts:
        raise SystemExit(f"duplicate short name: {short}")
    shorts.add(short)
    # Keep full live name <= 32: shrink prefix before dropping short uniqueness.
    herdr_name = f"{prefix}-{short}"
    if len(herdr_name) > 32:
        max_prefix = max(1, 32 - 1 - len(short))
        herdr_name = f"{prefix[:max_prefix].rstrip('-')}-{short}"
        herdr_name = sanitize_token(herdr_name)
    if not name_re.match(herdr_name):
        raise SystemExit(
            f"invalid herdr name derived: {herdr_name!r} "
            f"(need ^[a-z][a-z0-9_-]{{0,31}}$; shorten --label/--session-prefix)"
        )
    rows.append({"name": short, "herdr_name": herdr_name, "model": model})

# Detect herdr_name collisions within this fleet too.
seen_h = set()
for r in rows:
    if r["herdr_name"] in seen_h:
        raise SystemExit(f"duplicate herdr_name after clamp: {r['herdr_name']}")
    seen_h.add(r["herdr_name"])

raw = subprocess.check_output(["herdr", "agent", "list"], text=True)
live = {a.get("name") for a in json.loads(raw)["result"]["agents"] if a.get("name")}
collisions = [r["herdr_name"] for r in rows if r["herdr_name"] in live]
if collisions:
    raise SystemExit("herdr agent name collision(s): " + ", ".join(collisions) +
                     " — pick a new --label/--session-prefix or close the old tab")
print(json.dumps(rows))
PY
}

start_agent() {
  local herdr_name=$1 pane=$2 model=$3 short=$4
  local i resp rc
  for ((i=1; i<=READY_RETRIES; i++)); do
    herdr pane send-keys "$pane" enter 2>/dev/null || true
    sleep 1
    set +e
    resp=$(herdr agent start "$herdr_name" --kind pi --pane "$pane" --timeout "$START_TIMEOUT_MS" -- \
      --model "$model" \
      --session-dir "$OUTDIR/$short" \
      --name "${SESSION_PREFIX}-${short}" 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]] && ! grep -q '"error"' <<<"$resp"; then
      # ready gate: idle or done both mean interactive-ready (done = unseen idle)
      set +e
      herdr agent wait "$herdr_name" --until idle --until done --timeout 30000 >/dev/null 2>&1
      set -e
      printf '%s\n' "$resp"
      return 0
    fi
    log "start retry $i/$READY_RETRIES herdr_name=$herdr_name pane=$pane rc=$rc resp=$(echo "$resp" | tr '\n' ' ' | head -c 300)"
    sleep 2
  done
  log "FAILED start herdr_name=$herdr_name pane=$pane"
  # Prefer agent read if partially registered; else raw pane snapshot.
  herdr agent read "$herdr_name" --source recent-unwrapped --lines 40 2>/dev/null \
    || herdr pane read "$pane" --source recent-unwrapped --lines 40 2>/dev/null \
    || herdr pane read "$pane" --lines 40 2>/dev/null \
    || true
  return 1
}

split_pane() {
  local pane=$1 dir=$2 ratio=$3
  herdr pane split --pane "$pane" --direction "$dir" --ratio "$ratio" --cwd "$CWD" --no-focus \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])'
}

prompt_agent() {
  # Submit without herdr --wait: official --wait requires a lifecycle change within
  # 5s or returns agent_prompt_stalled; multi-model fanout made that race flaky.
  # Poll agent list for working|done|idle|blocked instead.
  local herdr_name=$1
  local prompt_file=$2
  local resp rc st i

  _submit() {
    set +e
    resp=$(herdr agent prompt "$herdr_name" "$(cat "$prompt_file")" 2>&1)
    rc=$?
    set -e
    if [[ $rc -ne 0 ]] || grep -q '"error"' <<<"$resp"; then
      return 1
    fi
    return 0
  }

  if ! _submit; then
    if grep -q 'agent_prompt_stalled' <<<"$resp"; then
      log "agent_prompt_stalled herdr_name=$herdr_name; read + retry once"
      herdr agent read "$herdr_name" --source recent-unwrapped --lines 40 >/dev/null 2>&1 || true
    else
      log "prompt submit failed herdr_name=$herdr_name; retry once"
    fi
    herdr agent send-keys "$herdr_name" enter 2>/dev/null || true
    sleep 1
    if ! _submit; then
      log "prompt submit failed herdr_name=$herdr_name resp=$(echo "$resp" | tr '\n' ' ' | head -c 300)"
      herdr agent read "$herdr_name" --source recent-unwrapped --lines 60 2>/dev/null | tail -n 40 || true
      return 1
    fi
  fi

  for ((i=1; i<=15; i++)); do
    st=$(herdr agent list 2>/dev/null | python3 -c 'import json,sys
d=json.loads(sys.stdin.read()); name=sys.argv[1]
for a in d["result"]["agents"]:
  if a.get("name")==name:
    print(a.get("agent_status","missing")); raise SystemExit
print("missing")' "$herdr_name" 2>/dev/null || echo missing)
    case "$st" in
      working|done|idle|blocked) return 0 ;;
      unknown)
        # present but unclassified — keep polling briefly, do not success-exit yet
        ;;
    esac
    sleep 2
  done
  log "prompt submitted but status still $st for $herdr_name (treating as ok if no error)"
  return 0
}

# --- preflight ---
log "preflight label=$LABEL cwd=$CWD agents=${#AGENTS[@]} prefix=$SESSION_PREFIX"
herdr status >/dev/null
AGENTS_JSON=$(validate_and_expand_agents)
printf '%s\n' "$AGENTS_JSON" >"$OUTDIR/agents.planned.json"
N=$(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' <<<"$AGENTS_JSON")
WS=$(pick_workspace)
log "workspace=$WS n=$N"

# --- tab ---
TAB_JSON=$(herdr tab create --workspace "$WS" --cwd "$CWD" --label "$LABEL" --no-focus)
printf '%s\n' "$TAB_JSON" >"$OUTDIR/tab.json"
ROOT=$(json_get "$TAB_JSON" 'print(d["result"]["root_pane"]["pane_id"])')
TAB_ID=$(json_get "$TAB_JSON" 'print(d["result"]["tab"]["tab_id"])')
printf '%s\n' "$TAB_ID" >"$OUTDIR/tab_id.txt"
python3 - <<PY
import json
from pathlib import Path
Path("$OUTDIR/policy.json").write_text(json.dumps({
    "auto_close": bool(int("$AUTO_CLOSE")),
    "verdict_marker": "VERDICT:",
    "label": "$LABEL",
    "session_prefix": "$SESSION_PREFIX",
    "tab_id": "$TAB_ID",
    "close_after": "main_agent_synthesis",
    "keep_on_partial_or_blocked": True,
}, indent=2) + "\n")
PY
log "tab=$TAB_ID root=$ROOT auto_close=$AUTO_CLOSE"

# --- panes ---
PANES=("$ROOT")
if [[ $N -ge 2 ]]; then
  PANES+=("$(split_pane "${PANES[0]}" right 0.5)")
fi
idx=0
while [[ ${#PANES[@]} -lt $N ]]; do
  base=${PANES[$idx]}
  dir=down
  if (( idx % 2 == 1 )); then dir=right; fi
  PANES+=("$(split_pane "$base" "$dir" 0.5)")
  idx=$((idx + 1))
done
log "panes=${PANES[*]}"

# materialize planned rows with panes
python3 - <<PY
import json
from pathlib import Path
rows=json.loads(Path("$OUTDIR/agents.planned.json").read_text())
panes="""${PANES[*]}""".split()
assert len(panes)==len(rows), (panes, rows)
out=[]
for r,p in zip(rows, panes):
    r=dict(r)
    r["pane_id"]=p
    r["tab_id"]="$TAB_ID"
    r["start_status"]="pending"
    out.append(r)
Path("$OUTDIR/agents.json").write_text(json.dumps(out, indent=2)+"\n")
Path("$OUTDIR/panes.map").write_text("".join(f'{r["name"]} {r["pane_id"]} {r["herdr_name"]}\n' for r in out))
PY

# --- start agents serially; continue on failure ---
FAIL=0
mapfile -t ROWS < <(python3 -c 'import json,sys
rows=json.load(open(sys.argv[1]))
for r in rows:
    print("|".join([r["name"], r["herdr_name"], r["model"], r["pane_id"]]))
' "$OUTDIR/agents.json")
if [[ ${#ROWS[@]} -eq 0 ]]; then
  log "FATAL: no agent rows parsed from agents.json"
  exit 1
fi
: >"$OUTDIR/start_status.tsv"
for row in "${ROWS[@]}"; do
  IFS='|' read -r short herdr_name model pane <<<"$row"
  mkdir -p "$OUTDIR/$short"
  log "starting short=$short herdr_name=$herdr_name pane=$pane model=$model"
  if start_agent "$herdr_name" "$pane" "$model" "$short" >/dev/null; then
    status=started
    log "started $herdr_name"
  else
    status=failed
    FAIL=1
    log "start failed $herdr_name"
  fi
  printf '%s\t%s\n' "$short" "$status" >>"$OUTDIR/start_status.tsv"
done

python3 - <<'PY' "$OUTDIR"
import json, subprocess, sys
from pathlib import Path
outdir = Path(sys.argv[1])
rows = json.loads((outdir / "agents.json").read_text())
st = {}
for line in (outdir / "start_status.tsv").read_text().splitlines():
    if not line.strip():
        continue
    s, status = line.split("\t", 1)
    st[s] = status
live = {
    a.get("name"): a
    for a in json.loads(subprocess.check_output(["herdr", "agent", "list"], text=True))["result"]["agents"]
}
for r in rows:
    r["start_status"] = st.get(r["name"], "unknown")
    m = live.get(r["herdr_name"])
    if m:
        r["agent_status"] = m.get("agent_status")
        r["terminal_title"] = m.get("terminal_title")
        r["pane_id"] = m.get("pane_id") or r.get("pane_id")
(outdir / "agents.json").write_text(json.dumps(rows, indent=2) + "\n")
print(json.dumps(rows, indent=2))
PY

# --- prompt started agents ---
PROMPT_FILE_ABS=$(readlink -f "$PROMPT_FILE")
for row in "${ROWS[@]}"; do
  IFS='|' read -r short herdr_name model pane <<<"$row"
  st=$(python3 -c 'import json,sys; rows=json.load(open(sys.argv[1]));
print(next(r["start_status"] for r in rows if r["name"]==sys.argv[2]))' "$OUTDIR/agents.json" "$short")
  if [[ "$st" != "started" ]]; then
    log "skip prompt $herdr_name (start_status=$st)"
    continue
  fi
  log "prompting $herdr_name"
  if prompt_agent "$herdr_name" "$PROMPT_FILE_ABS"; then
    log "prompted $herdr_name (working)"
    python3 -c 'import json,sys; p=sys.argv[1]; n=sys.argv[2]; rows=json.load(open(p));
[(r.update({"prompt_status":"working"}) if r["herdr_name"]==n else None) for r in rows];
json.dump(rows, open(p,"w"), indent=2); open(p,"a").write("\n")' "$OUTDIR/agents.json" "$herdr_name"
  else
    FAIL=1
    log "prompt failed $herdr_name"
    python3 -c 'import json,sys; p=sys.argv[1]; n=sys.argv[2]; rows=json.load(open(p));
[(r.update({"prompt_status":"failed"}) if r["herdr_name"]==n else None) for r in rows];
json.dump(rows, open(p,"w"), indent=2); open(p,"a").write("\n")' "$OUTDIR/agents.json" "$herdr_name"
  fi
done

# status dump
herdr agent list | python3 -c '
import json,sys
from pathlib import Path
want={r["herdr_name"] for r in json.loads(Path("'"$OUTDIR"'/agents.json").read_text())}
d=json.loads(sys.stdin.read())
for a in d["result"]["agents"]:
    if a.get("name") in want:
        print(a.get("name"), a.get("pane_id"), a.get("agent_status"))
'

cat >"$OUTDIR/WATCHDOG_HINT.txt" <<EOF
# Run via bg_run (do not close tab here):
bash $SKILL_DIR/watchdog.sh --outdir $OUTDIR
# Main agent closes after synthesis:
# bash $SKILL_DIR/close.sh --outdir $OUTDIR
EOF
printf '%s\n' "$SKILL_DIR" >"$OUTDIR/skill_dir.txt"

if [[ "$FAIL" -ne 0 ]]; then
  log "LAUNCH_PARTIAL tab=$TAB_ID outdir=$OUTDIR (some start/prompt failures)"
  echo "TAB_ID=$TAB_ID"
  echo "OUTDIR=$OUTDIR"
  echo "AUTO_CLOSE=$AUTO_CLOSE"
  echo "STATUS=partial"
  exit 1
fi

log "LAUNCH_OK tab=$TAB_ID outdir=$OUTDIR auto_close=$AUTO_CLOSE"
echo "TAB_ID=$TAB_ID"
echo "OUTDIR=$OUTDIR"
echo "AUTO_CLOSE=$AUTO_CLOSE"
echo "STATUS=ok"
