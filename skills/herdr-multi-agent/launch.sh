#!/usr/bin/env bash
# Launch N interactive Pi agents in a Herdr tab, prompt them, write mapping files.
# Does NOT run the watchdog (use watchdog.sh via bg_run).
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_FLEET_FILE="$SKILL_DIR/fleet.defaults"

# Portable realpath (avoid GNU readlink -f)
abspath() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

usage() {
  cat <<'EOF'
Usage: launch.sh --label NAME --cwd PATH --outdir PATH --prompt-file PATH \
  [--agent name=provider/model[:thinking] ...]
  [--fleet-file PATH]
  [--workspace ID] [--session-prefix STR] [--start-timeout-ms N] [--ready-retries N]
  [--skip-model-preflight] [--kind KIND]
  [--keep|--no-close] [--force]

Creates a Herdr tab, splits panes, starts Pi serially with shell-ready retries,
prompts every agent, writes mapping + policy under outdir.

If no --agent is given, loads name=model lines from --fleet-file (default:
$SKILL_DIR/fleet.defaults). Models must already exist in the caller's pi config.
Herdr agent names are namespaced as <session-prefix>-<short-name> to avoid collisions.
--keep / --no-close => policy.auto_close=false.
--force allows reusing a non-empty outdir (also clears prior results/verdicts).
Requires: bash, python3, herdr on PATH, pi on PATH (for model preflight unless skipped).
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
SKIP_MODEL_PREFLIGHT=0
AGENT_KIND="pi"
AGENTS=()
TAB_ID=""
CREATED_TAB=0

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
    --kind) AGENT_KIND=${2:?}; shift 2 ;;
    --skip-model-preflight) SKIP_MODEL_PREFLIGHT=1; shift ;;
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
command -v herdr >/dev/null || { echo "herdr not on PATH" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 not on PATH" >&2; exit 2; }

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

# Prompt must include harvestable VERDICT marker (unless empty file edge — still fail).
if ! grep -q 'VERDICT:' "$PROMPT_FILE"; then
  echo "prompt-file must contain 'VERDICT:' trailer marker for harvest" >&2
  exit 2
fi

load_fleet_file() {
  local path=$1 line
  [[ -f "$path" ]] || { echo "fleet file missing: $path" >&2; exit 2; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}
    # trim
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [[ -z "$line" ]] && continue
    if [[ "$line" != *=* ]]; then
      echo "invalid fleet line (need name=model): $line" >&2
      exit 2
    fi
    AGENTS+=("$line")
  done <"$path"
  if [[ ${#AGENTS[@]} -eq 0 ]]; then
    echo "fleet file empty (only comments?): $path" >&2
    echo "pass --agent name=model ... or --fleet-file with entries; see fleet.example" >&2
    exit 2
  fi
}

if [[ ${#AGENTS[@]} -eq 0 ]]; then
  FLEET_FILE=${FLEET_FILE:-$DEFAULT_FLEET_FILE}
  load_fleet_file "$FLEET_FILE"
  if [[ "$(abspath "$FLEET_FILE")" == "$(abspath "$DEFAULT_FLEET_FILE")" ]]; then
    echo "NOTE: using shipped fleet.defaults (author-specific models)." >&2
    echo "      Third parties should pass --agent / --fleet-file or edit fleet.defaults." >&2
  fi
elif [[ -n "$FLEET_FILE" ]]; then
  echo "ignore --fleet-file because --agent was also provided" >&2
fi

SESSION_PREFIX=${SESSION_PREFIX:-$LABEL}
SESSION_PREFIX=$(printf '%s' "$SESSION_PREFIX" | tr -c 'a-zA-Z0-9_-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
[[ -n "$SESSION_PREFIX" ]] || SESSION_PREFIX="review"

if [[ -e "$OUTDIR/agents.json" && "$FORCE" -ne 1 ]]; then
  echo "outdir already has agents.json: $OUTDIR (pass --force to reuse)" >&2
  exit 2
fi
mkdir -p "$OUTDIR"

# On --force reuse: clear stale harvest artifacts so old VERDICT files cannot false-pass.
if [[ "$FORCE" -eq 1 ]]; then
  rm -rf "$OUTDIR/results"
  # clear per-agent verdict.md but keep structure after we know shorts
  find "$OUTDIR" -mindepth 2 -maxdepth 2 -name 'verdict.md' -delete 2>/dev/null || true
fi

LOG="$OUTDIR/launch.log"
exec > >(tee -a "$LOG") 2>&1

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

# Best-effort: if we created a tab and die before STATUS lines, leave a breadcrumb.
on_exit() {
  local rc=$?
  if [[ "$CREATED_TAB" -eq 1 && -n "$TAB_ID" ]]; then
    if [[ ! -f "$OUTDIR/launch_exit.json" ]]; then
      python3 -c 'import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "tab_id": sys.argv[2],
  "exit_rc": int(sys.argv[3]),
  "note": "launch exited; tab may still be open — close.sh --force if orphaned",
}, indent=2)+"\n")' "$OUTDIR/launch_exit.json" "$TAB_ID" "$rc" 2>/dev/null || true
    fi
  fi
}
trap on_exit EXIT

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
name_re = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")

def sanitize_token(s: str, max_len: int = 32) -> str:
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9_-]+", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    if not s:
        s = "agent"
    if not s[0].isalpha():
        s = "a" + s
    return s[:max_len]

prefix = sanitize_token(prefix, 32)
rows = []
shorts = set()
for spec in specs:
    if "=" not in spec:
        raise SystemExit(f"invalid --agent (need name=model): {spec!r}")
    short, model = spec.split("=", 1)
    # leave room for at least "a-" prefix (2 chars) when namespaced
    short = sanitize_token(short, 30)
    if not name_re.match(short):
        raise SystemExit(f"invalid agent short name {short!r} (want ^[a-z][a-z0-9_-]{{0,31}}$)")
    if not model.strip():
        raise SystemExit(f"empty model for {short}")
    if short in shorts:
        raise SystemExit(f"duplicate short name: {short}")
    shorts.add(short)

    # herdr live name <= 32: prefer prefix-short; fall back to short alone
    budget = 32 - 1 - len(short)  # for "prefix-short"
    if budget >= 1:
        p = sanitize_token(prefix, budget)
        if not p:
            p = "r"
        # re-trim budget after sanitize
        p = p[:budget].rstrip("-") or "r"
        herdr_name = f"{p}-{short}"
    else:
        herdr_name = short[:32]
    herdr_name = herdr_name[:32]
    if not name_re.match(herdr_name):
        raise SystemExit(
            f"invalid herdr name derived: {herdr_name!r} "
            f"(need ^[a-z][a-z0-9_-]{{0,31}}$; shorten --label/--session-prefix)"
        )
    if len(herdr_name) > 32:
        raise SystemExit(f"herdr_name still too long: {herdr_name!r} len={len(herdr_name)}")
    rows.append({"name": short, "herdr_name": herdr_name, "model": model.strip()})

seen_h = set()
for r in rows:
    if r["herdr_name"] in seen_h:
        raise SystemExit(f"duplicate herdr_name after clamp: {r['herdr_name']}")
    seen_h.add(r["herdr_name"])

raw = subprocess.check_output(["herdr", "agent", "list"], text=True)
live = {a.get("name") for a in json.loads(raw)["result"]["agents"] if a.get("name")}
collisions = [r["herdr_name"] for r in rows if r["herdr_name"] in live]
if collisions:
    raise SystemExit(
        "herdr agent name collision(s): "
        + ", ".join(collisions)
        + " — pick a new --label/--session-prefix or close the old tab"
    )
print(json.dumps(rows))
PY
}

model_preflight() {
  # Best-effort: ensure each provider/model appears in `pi --list-models`.
  # Model strings may include :thinking suffix.
  if [[ "$SKIP_MODEL_PREFLIGHT" -eq 1 ]]; then
    log "model preflight skipped"
    return 0
  fi
  if ! command -v pi >/dev/null; then
    log "WARN: pi not on PATH; skip model preflight"
    return 0
  fi
  local list
  set +e
  list=$(pi --list-models 2>/dev/null)
  local rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$list" ]]; then
    log "WARN: pi --list-models failed; skip model preflight"
    return 0
  fi
  python3 - <<'PY' "$list" "${AGENTS[@]}"
import sys
raw = sys.argv[1]
specs = sys.argv[2:]
# Build searchable haystack lowercased
hay = raw.lower()
missing = []
for spec in specs:
    if "=" not in spec:
        continue
    short, model = spec.split("=", 1)
    model = model.strip()
    base = model.split(":", 1)[0]  # drop thinking
    # accept provider/id or bare id match against list lines
    parts = base.split("/", 1)
    candidates = [base.lower()]
    if len(parts) == 2:
        candidates.append(parts[1].lower())
        candidates.append(parts[0].lower() + " " + parts[1].lower())
    ok = any(c and c in hay for c in candidates)
    if not ok:
        missing.append(f"{short}={model}")
if missing:
    sys.stderr.write(
        "model preflight failed — not found via `pi --list-models`:\n  - "
        + "\n  - ".join(missing)
        + "\nFix auth/models.json, pass different --agent/--fleet-file, or --skip-model-preflight\n"
    )
    sys.exit(3)
print("model_preflight_ok", len(specs))
PY
}

start_agent() {
  local herdr_name=$1 pane=$2 model=$3 short=$4
  local i resp rc busy_retries=0 hard_fail_retries=0
  # busy shell: up to READY_RETRIES; other errors (bad model etc.): max 2 tries
  for ((i=1; i<=READY_RETRIES; i++)); do
    herdr pane send-keys "$pane" enter 2>/dev/null || true
    sleep 1
    set +e
    resp=$(herdr agent start "$herdr_name" --kind "$AGENT_KIND" --pane "$pane" --timeout "$START_TIMEOUT_MS" -- \
      --model "$model" \
      --session-dir "$OUTDIR/$short" \
      --name "$herdr_name" 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]] && ! grep -q '"error"' <<<"$resp"; then
      set +e
      herdr agent wait "$herdr_name" --until idle --until done --timeout 30000 >/dev/null 2>&1
      set -e
      printf '%s\n' "$resp"
      return 0
    fi
    # Classify: pane busy → keep retrying; else fail fast after 2
    if grep -Eqi 'agent_pane_busy|not an available shell|pane_busy' <<<"$resp"; then
      busy_retries=$((busy_retries + 1))
      log "start busy-retry $busy_retries/$READY_RETRIES herdr_name=$herdr_name pane=$pane"
      sleep 2
      continue
    fi
    hard_fail_retries=$((hard_fail_retries + 1))
    log "start hard-fail try $hard_fail_retries/2 herdr_name=$herdr_name rc=$rc resp=$(echo "$resp" | tr '\n' ' ' | head -c 300)"
    if (( hard_fail_retries >= 2 )); then
      break
    fi
    sleep 2
  done
  log "FAILED start herdr_name=$herdr_name pane=$pane"
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

# Balanced-ish pane tree: BFS alternate right/down from each existing pane.
build_panes() {
  local n=$1
  local root=$2
  PANES=("$root")
  local i=0
  local dir toggle=0
  while [[ ${#PANES[@]} -lt $n ]]; do
    local base=${PANES[$i]}
    if (( toggle % 2 == 0 )); then dir=right; else dir=down; fi
    # split current leaf; ratio 0.5 keeps halves usable longer than cascade-from-root
    PANES+=("$(split_pane "$base" "$dir" 0.5)")
    i=$((i + 1))
    toggle=$((toggle + 1))
    # when we've split every current leaf once, continue BFS
    if (( i >= ${#PANES[@]} - 1 )) && [[ ${#PANES[@]} -lt $n ]]; then
      : # keep going; i walks newly added too
    fi
  done
}

prompt_agent() {
  local herdr_name=$1
  local prompt_file=$2
  local resp rc st i

  _submit() {
    # Use prompt file via stdin-ish: pass content; herdr CLI takes string arg.
    # Avoid embedding issues by reading file in python and passing carefully.
    set +e
    resp=$(python3 - <<'PY' "$herdr_name" "$prompt_file"
import subprocess, sys
name, path = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8", errors="replace").read()
# herdr agent prompt NAME TEXT
proc = subprocess.run(
    ["herdr", "agent", "prompt", name, text],
    capture_output=True,
    text=True,
)
sys.stdout.write(proc.stdout or "")
sys.stderr.write(proc.stderr or "")
sys.exit(proc.returncode)
PY
)
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
      unknown) ;;
      missing)
        # not registered — fail
        ;;
    esac
    sleep 2
  done
  log "prompt submitted but status still $st for $herdr_name (NOT treating as success)"
  return 1
}

# --- preflight ---
log "preflight label=$LABEL cwd=$CWD agents=${#AGENTS[@]} prefix=$SESSION_PREFIX kind=$AGENT_KIND"
herdr status >/dev/null
model_preflight
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
CREATED_TAB=1
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
    "agent_kind": "$AGENT_KIND",
    "close_after": "main_agent_synthesis",
    "keep_on_partial_or_blocked": True,
}, indent=2) + "\n")
PY
log "tab=$TAB_ID root=$ROOT auto_close=$AUTO_CLOSE"

# --- panes (BFS balanced-ish) ---
build_panes "$N" "$ROOT"
log "panes=${PANES[*]}"

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
# clear stale verdict.md under known shorts on force
for r in out:
    vp = Path("$OUTDIR")/r["name"]/"verdict.md"
    if vp.exists():
        vp.unlink()
PY

# --- start agents serially ---
FAIL=0
ROWS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] && ROWS+=("$line")
done < <(python3 -c 'import json,sys
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
PROMPT_FILE_ABS=$(abspath "$PROMPT_FILE")
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
    log "prompted $herdr_name (accepted)"
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

python3 -c 'import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
  "tab_id": sys.argv[2],
  "exit_rc": int(sys.argv[3]),
  "status": sys.argv[4],
}, indent=2)+"\n")' \
  "$OUTDIR/launch_exit.json" "$TAB_ID" "$FAIL" "$([[ $FAIL -eq 0 ]] && echo ok || echo partial)"

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
