#!/usr/bin/env bash
# Launch N interactive Pi agents in a Herdr tab, prompt them, write mapping files.
# Does NOT run the watchdog (Grok: run watchdog.sh via run_terminal_command background:true).
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
  [--agent name=provider/model[:thinking]|name=kind:model ...]
  [--fleet-file PATH]
  [--workspace ID] [--session-prefix STR] [--start-timeout-ms N] [--ready-retries N]
  [--skip-model-preflight] [--kind KIND]
  [--serial-prompt|--parallel-prompt] [--keep|--no-close] [--force]

Creates a Herdr tab, splits panes, starts agents serially with shell-ready retries,
prompts every started agent (parallel fanout by default), writes mapping + policy
under outdir. --serial-prompt waits for each prompt accept before the next.

If no --agent is given, loads name=model lines from --fleet-file (default:
$SKILL_DIR/fleet.defaults).

Spec formats:
  name=provider/model[:thinking]   # default kind=pi (or global --kind)
  name=kind:model                  # per-agent kind when KIND is a herdr agent kind
                                   # e.g. fable5=cursor:claude-fable-5-thinking-high

Pi models must exist in the caller's pi config; cursor models are checked via
`cursor-agent --list-models` (bare `agent` only if it is cursor-cli, not Grok).
Cursor agents start with --trust --force (UI: Run Everything) for unattended fleets.
Missing pi/cursor CLIs required by the fleet fail preflight hard (unless skipped).
Herdr agent names are namespaced as <session-prefix>-<short-name> to avoid collisions.
--keep / --no-close => policy.auto_close=false.
--force allows reusing a non-empty outdir (also clears prior results/verdicts).
Requires: bash, python3, herdr on PATH; pi/cursor-agent on PATH for kind-specific preflight.
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
PARALLEL_PROMPT=1
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
    --serial-prompt) PARALLEL_PROMPT=0; shift ;;
    --parallel-prompt) PARALLEL_PROMPT=1; shift ;;
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
      echo "invalid fleet line (need name=model or name=kind:model): $line" >&2
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
  python3 - <<'PY' "$SKILL_DIR" "$SESSION_PREFIX" "$AGENT_KIND" "${AGENTS[@]}"
import json, subprocess, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import fleet_lib as fl

prefix = sys.argv[2]
default_kind = (sys.argv[3] or "pi").strip().lower() or "pi"
specs = sys.argv[4:]

rows = []
shorts = set()
try:
    for spec in specs:
        short, kind, model = fl.parse_agent_spec(spec, default_kind)
        if short in shorts:
            raise fl.FleetError(f"duplicate short name: {short}")
        shorts.add(short)
        herdr_name = fl.expand_herdr_name(prefix, short)
        rows.append({
            "name": short,
            "herdr_name": herdr_name,
            "model": model,
            "kind": kind,
        })
except fl.FleetError as e:
    raise SystemExit(str(e))

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
  # Kind-aware preflight via fleet_lib:
  #   pi/cursor missing CLI or list-models failure → hard fail (exit 3)
  #   unknown kinds → WARN skip
  if [[ "$SKIP_MODEL_PREFLIGHT" -eq 1 ]]; then
    log "model preflight skipped"
    return 0
  fi
  python3 - <<'PY' "$SKILL_DIR" "$AGENT_KIND" "$OUTDIR" "${AGENTS[@]}"
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import fleet_lib as fl

default_kind = (sys.argv[2] or "pi").strip().lower() or "pi"
outdir = Path(sys.argv[3])
specs = sys.argv[4:]
try:
    missing, skipped = fl.preflight_specs(specs, default_kind, hard_fail_missing_cli=True)
except fl.FleetError as e:
    sys.stderr.write(str(e) + "\n")
    sys.exit(3)
if missing:
    sys.stderr.write(
        "model preflight failed — not found in kind-specific model list:\n  - "
        + "\n  - ".join(missing)
        + "\nFix auth/CLI login, pass different --agent/--fleet-file, or --skip-model-preflight\n"
    )
    sys.exit(3)
skipped_set = set(skipped)
kept = []
for spec in specs:
    if "=" not in spec:
        continue
    _short, kind, _model = fl.parse_agent_spec(spec, default_kind)
    if kind in skipped_set:
        print(f"WARN: dropping {spec} (kind={kind} unavailable)", file=sys.stderr)
        continue
    kept.append(spec)
if not kept:
    sys.stderr.write("model preflight dropped every agent\n")
    sys.exit(3)
(outdir / "kept_specs.txt").write_text("\n".join(kept) + "\n")
for k in skipped:
    if k not in ("pi", "cursor"):
        print(f"WARN: no model preflight for kind={k}; continuing", file=sys.stderr)
print("model_preflight_ok", len(kept), "skipped_kinds=", ",".join(skipped) or "-")
PY
  if [[ -f "$OUTDIR/kept_specs.txt" ]]; then
    AGENTS=()
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] && AGENTS+=("$line")
    done < "$OUTDIR/kept_specs.txt"
  fi
}

start_agent_args() {
  # Print NUL-separated native args for herdr agent start -- <args...>
  # Source of truth: fleet_lib.start_native_args
  local kind=$1 model=$2 short=$3 herdr_name=$4
  python3 - <<'PY' "$SKILL_DIR" "$kind" "$model" "$OUTDIR/$short" "$herdr_name"
import sys
sys.path.insert(0, sys.argv[1])
import fleet_lib as fl
args = fl.start_native_args(
    sys.argv[2],
    sys.argv[3],
    session_dir=sys.argv[4],
    herdr_name=sys.argv[5],
)
sys.stdout.buffer.write(b"\0".join(a.encode() for a in args) + (b"\0" if args else b""))
PY
}

cursor_cli_bin() {
  python3 - <<'PY' "$SKILL_DIR"
import sys
sys.path.insert(0, sys.argv[1])
import fleet_lib as fl
print(fl.which_cursor_cli() or "")
PY
}

# herdr --kind cursor types PATH `cursor-agent` (official updater clobber target).
# Start the 37890 wrapper by name, then attach the herdr agent name.
wait_name_cursor_pane() {
  local pane=$1 herdr_name=$2 timeout_ms=$3
  python3 - <<'PY' "$pane" "$herdr_name" "$timeout_ms"
import json, subprocess, sys, time
pane, name, timeout_ms = sys.argv[1], sys.argv[2], int(sys.argv[3])
deadline = time.time() + max(timeout_ms, 3000) / 1000.0
while time.time() < deadline:
    p = subprocess.run(["herdr", "agent", "list"], capture_output=True, text=True)
    try:
        data = json.loads((p.stdout or "").strip() or "{}")
    except json.JSONDecodeError:
        time.sleep(1)
        continue
    agents = (data.get("result") or {}).get("agents") or []
    for a in agents:
        if a.get("pane_id") != pane:
            continue
        agent = (a.get("agent") or "").lower()
        if agent not in ("cursor", "cursor-agent"):
            continue
        cur = a.get("name") or ""
        if cur == name:
            print("named")
            raise SystemExit(0)
        target = cur or pane
        r = subprocess.run(
            ["herdr", "agent", "rename", target, name],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            print("renamed")
            raise SystemExit(0)
        print("rename-failed", (r.stderr or r.stdout or "")[:300], file=sys.stderr)
        raise SystemExit(1)
    time.sleep(1)
print("timeout waiting for cursor on", pane, file=sys.stderr)
raise SystemExit(1)
PY
}

start_agent() {
  local herdr_name=$1 pane=$2 model=$3 short=$4 kind=$5
  local i resp rc busy_retries=0 hard_fail_retries=0
  local -a native_args=()
  local cursor_bin=""
  # busy shell: up to READY_RETRIES; other errors (bad model etc.): max 2 tries
  for ((i=1; i<=READY_RETRIES; i++)); do
    herdr pane send-keys "$pane" enter 2>/dev/null || true
    sleep 1
    native_args=()
    while IFS= read -r -d '' tok; do
      native_args+=("$tok")
    done < <(start_agent_args "$kind" "$model" "$short" "$herdr_name")
    set +e
    if [[ "$kind" == "cursor" ]]; then
      cursor_bin=$(cursor_cli_bin)
      if [[ -z "$cursor_bin" ]]; then
        rc=1
        resp="cursor-agent-proxy/cursor-agent not on PATH"
      else
        # herdr pane run <PANE_ID> <COMMAND>... — a bare `--` is COMMAND[0]
        # and is typed into the shell (`zsh: command not found: --`).
        # Unlike `herdr agent start ... -- [AGENT_ARG]...`, pane run has no
        # option terminator; `--model`/`--trust`/`--force` are already COMMAND.
        resp=$(herdr pane run "$pane" "$cursor_bin" "${native_args[@]}" 2>&1)
        rc=$?
        if [[ $rc -eq 0 ]]; then
          wait_name_cursor_pane "$pane" "$herdr_name" "$START_TIMEOUT_MS"
          rc=$?
          if [[ $rc -ne 0 ]]; then
            resp="${resp}"$'\n'"wait_name_cursor_pane failed"
          fi
        fi
      fi
    else
      resp=$(herdr agent start "$herdr_name" --kind "$kind" --pane "$pane" --timeout "$START_TIMEOUT_MS" -- \
        "${native_args[@]}" 2>&1)
      rc=$?
    fi
    set -e
    if [[ $rc -eq 0 ]] && ! grep -q '"error"' <<<"$resp"; then
      set +e
      herdr agent wait "$herdr_name" --until idle --until done --timeout 30000 >/dev/null 2>&1
      set -e
      # Non-pi TUIs (cursor-agent etc.) need a beat after interactive_ready before
      # composer accepts herdr agent prompt; otherwise text lands half-submitted.
      # Enter focuses the composer / dismisses splash so the first prompt is not dropped.
      if [[ "$kind" != "pi" ]]; then
        sleep 3
        herdr agent send-keys "$herdr_name" enter 2>/dev/null || true
        sleep 1
      fi
      printf '%s\n' "$resp"
      return 0
    fi
    # Classify: pane busy → keep retrying; else fail fast after 2
    if grep -Eqi 'agent_pane_busy|not an available shell|pane_busy' <<<"$resp"; then
      busy_retries=$((busy_retries + 1))
      log "start busy-retry $busy_retries/$READY_RETRIES herdr_name=$herdr_name kind=$kind pane=$pane"
      sleep 2
      continue
    fi
    hard_fail_retries=$((hard_fail_retries + 1))
    log "start hard-fail try $hard_fail_retries/2 herdr_name=$herdr_name kind=$kind rc=$rc resp=$(echo "$resp" | tr '\n' ' ' | head -c 300)"
    if (( hard_fail_retries >= 2 )); then
      break
    fi
    sleep 2
  done
  log "FAILED start herdr_name=$herdr_name kind=$kind pane=$pane"
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
  # $1 herdr_name  $2 prompt_file  $3 kind (default pi)
  local herdr_name=$1
  local prompt_file=$2
  local kind=${3:-pi}
  local resp rc st i
  local saw_active=0
  local idle_ticks=0
  local nudged=0
  local resubmitted=0

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
      log "agent_prompt_stalled herdr_name=$herdr_name kind=$kind; read + retry once"
      herdr agent read "$herdr_name" --source recent-unwrapped --lines 40 >/dev/null 2>&1 || true
    else
      log "prompt submit failed herdr_name=$herdr_name kind=$kind; retry once"
    fi
    herdr agent send-keys "$herdr_name" enter 2>/dev/null || true
    sleep 1
    if ! _submit; then
      log "prompt submit failed herdr_name=$herdr_name kind=$kind resp=$(echo "$resp" | tr '\n' ' ' | head -c 300)"
      herdr agent read "$herdr_name" --source recent-unwrapped --lines 60 2>/dev/null | tail -n 40 || true
      return 1
    fi
  fi

  # Prefer observing working/done/blocked.
  # pi: accept idle quickly — never re-paste prompt (avoids double-submit on status lag).
  # non-pi (cursor): idle ≠ empty composer. Title change / Pasted text / prompt
  # fingerprint = already landed → enter-only, never stack a full re-paste.
  # Full re-prompt only when the composer still looks empty. Policy:
  # fleet_lib.nonpi_prompt_policy / prompt_already_landed.
  local title=""
  local saw_landed=0
  local accept_now=0

  _fetch_state() {
    python3 -c 'import json,sys
d=json.loads(sys.stdin.read()); name=sys.argv[1]
for a in d["result"]["agents"]:
  if a.get("name")==name:
    title=a.get("terminal_title_stripped") or a.get("terminal_title") or ""
    print(a.get("agent_status","missing") + "\t" + title.replace("\t"," ").replace("\n"," "))
    raise SystemExit
print("missing\t")' "$herdr_name" 2>/dev/null || echo missing$'\t'
  }

  _landed_now() {
    python3 - <<'PY' "$SKILL_DIR" "$title" "$herdr_name" "$prompt_file" "$idle_ticks"
import subprocess, sys
sys.path.insert(0, sys.argv[1])
import fleet_lib as fl
title, name, prompt_path, tick_s = sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
prompt = open(prompt_path, encoding="utf-8", errors="replace").read()
tick = int(tick_s)
pane = ""
if not fl.title_left_cold(title) and tick in (3, 6):
    try:
        pane = subprocess.check_output(
            ["herdr", "agent", "read", name, "--source", "recent-unwrapped",
             "--lines", "80", "--format", "text"],
            text=True, timeout=15,
        )
    except Exception:
        pane = ""
print("yes" if fl.prompt_already_landed(title=title, pane_text=pane, prompt_text=prompt) else "no")
PY
  }

  _nonpi_recover_tick() {
    idle_ticks=$((idle_ticks + 1))
    local landed=0
    if [[ "$saw_landed" -eq 1 ]] || [[ "$(_landed_now)" == "yes" ]]; then
      landed=1
      saw_landed=1
    fi
    local action
    action=$(python3 -c 'import sys
sys.path.insert(0, sys.argv[1])
import fleet_lib as fl
print(fl.nonpi_prompt_policy(idle_ticks=int(sys.argv[2]), landed=sys.argv[3]=="1"))' \
      "$SKILL_DIR" "$idle_ticks" "$landed")
    case "$action" in
      enter)
        if [[ "$nudged" -eq 0 ]]; then
          nudged=1
          log "prompt still $st for $herdr_name kind=$kind; enter-only nudge once"
          herdr agent send-keys "$herdr_name" enter 2>/dev/null || true
        fi
        ;;
      repaste)
        if [[ "$resubmitted" -eq 0 ]]; then
          resubmitted=1
          log "prompt still $st for $herdr_name kind=$kind; full re-prompt once (no land evidence)"
          _submit || true
        fi
        ;;
      skip_repaste)
        log "prompt still $st for $herdr_name kind=$kind; already landed — skip full re-prompt"
        ;;
      accept)
        log "prompt accepted as landed ($st) herdr_name=$herdr_name kind=$kind"
        accept_now=1
        ;;
      fail)
        ;;
      wait) ;;
    esac
  }

  # 30 * 2s = 60s. Landed+idle returns early via policy (accept after enter).
  for ((i=1; i<=30; i++)); do
    local state
    state=$(herdr agent list 2>/dev/null | _fetch_state)
    st=${state%%$'\t'*}
    title=${state#*$'\t'}
    [[ "$st" == "$state" ]] && title=""
    case "$st" in
      working)
        saw_active=1
        return 0
        ;;
      done|blocked)
        if [[ "$kind" == "pi" || "$saw_active" -eq 1 ]]; then
          return 0
        fi
        log "non-pi $st without working for $herdr_name; treating as unseen idle"
        _nonpi_recover_tick
        ;;
      idle)
        if [[ "$saw_active" -eq 1 ]]; then
          return 0
        fi
        if [[ "$kind" == "pi" ]]; then
          idle_ticks=$((idle_ticks + 1))
          # Fast pi turns can settle idle before we sample working; accept soon.
          if [[ "$idle_ticks" -ge 2 ]]; then
            log "prompt accepted as idle (pi) herdr_name=$herdr_name"
            return 0
          fi
        else
          _nonpi_recover_tick
        fi
        ;;
      unknown) ;;
      missing) ;;
    esac
    if [[ "$accept_now" -eq 1 ]]; then
      return 0
    fi
    sleep 2
  done
  if [[ "$saw_landed" -eq 1 ]]; then
    log "prompt submitted; still $st but already landed — treating as accepted herdr_name=$herdr_name kind=$kind"
    return 0
  fi
  log "prompt submitted but status still $st for $herdr_name kind=$kind (NOT treating as success)"
  return 1
}

prompt_one() {
  # $1 short  $2 herdr_name  $3 kind
  # Writes $OUTDIR/$short/prompt_status.txt so parallel jobs do not clobber agents.json.
  local short=$1 herdr_name=$2 kind=$3
  local stfile="$OUTDIR/$short/prompt_status.txt"
  mkdir -p "$OUTDIR/$short"
  log "prompting $herdr_name kind=$kind"
  if prompt_agent "$herdr_name" "$PROMPT_FILE_ABS" "$kind"; then
    log "prompted $herdr_name (accepted)"
    printf '%s\n' "working" >"$stfile"
    return 0
  fi
  log "prompt failed $herdr_name"
  printf '%s\n' "failed" >"$stfile"
  return 1
}

apply_prompt_statuses() {
  python3 - <<'PY' "$OUTDIR"
import json, sys
from pathlib import Path
outdir = Path(sys.argv[1])
rows = json.loads((outdir / "agents.json").read_text())
for r in rows:
    if r.get("start_status") != "started":
        continue
    p = outdir / r["name"] / "prompt_status.txt"
    r["prompt_status"] = p.read_text().strip() if p.exists() else "unknown"
(outdir / "agents.json").write_text(json.dumps(rows, indent=2) + "\n")
PY
}

# --- preflight ---
log "preflight label=$LABEL cwd=$CWD agents=${#AGENTS[@]} prefix=$SESSION_PREFIX kind=$AGENT_KIND parallel_prompt=$PARALLEL_PROMPT"
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
rows=json.loads(Path("$OUTDIR/agents.planned.json").read_text())
kinds=sorted({r.get("kind","pi") for r in rows})
Path("$OUTDIR/policy.json").write_text(json.dumps({
    "auto_close": bool(int("$AUTO_CLOSE")),
    "verdict_marker": "VERDICT:",
    "label": "$LABEL",
    "session_prefix": "$SESSION_PREFIX",
    "tab_id": "$TAB_ID",
    "agent_kind_default": "$AGENT_KIND",
    "agent_kinds": kinds,
    "parallel_prompt": bool(int("$PARALLEL_PROMPT")),
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
    print("|".join([r["name"], r["herdr_name"], r["model"], r["pane_id"], r.get("kind") or "pi"]))
' "$OUTDIR/agents.json")
if [[ ${#ROWS[@]} -eq 0 ]]; then
  log "FATAL: no agent rows parsed from agents.json"
  exit 1
fi
: >"$OUTDIR/start_status.tsv"
for row in "${ROWS[@]}"; do
  IFS='|' read -r short herdr_name model pane kind <<<"$row"
  mkdir -p "$OUTDIR/$short"
  log "starting short=$short herdr_name=$herdr_name pane=$pane kind=$kind model=$model"
  if start_agent "$herdr_name" "$pane" "$model" "$short" "$kind" >/dev/null; then
    status=started
    log "started $herdr_name kind=$kind"
  else
    status=failed
    FAIL=1
    log "start failed $herdr_name kind=$kind"
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
# Default: one background job per started agent (submit+accept wait overlap).
# --serial-prompt: old one-by-one wait. agent start stays serial either way.
PROMPT_FILE_ABS=$(abspath "$PROMPT_FILE")
PROMPT_PIDS=()
PROMPT_N=0
PROMPT_MODE=serial
if [[ "$PARALLEL_PROMPT" -eq 1 ]]; then
  PROMPT_MODE=parallel
fi
log "prompt-fanout start mode=$PROMPT_MODE"
for row in "${ROWS[@]}"; do
  IFS='|' read -r short herdr_name model pane kind <<<"$row"
  st=$(python3 -c 'import json,sys; rows=json.load(open(sys.argv[1]));
print(next(r["start_status"] for r in rows if r["name"]==sys.argv[2]))' "$OUTDIR/agents.json" "$short")
  if [[ "$st" != "started" ]]; then
    log "skip prompt $herdr_name (start_status=$st)"
    continue
  fi
  PROMPT_N=$((PROMPT_N + 1))
  if [[ "$PARALLEL_PROMPT" -eq 1 ]]; then
    prompt_one "$short" "$herdr_name" "$kind" &
    PROMPT_PIDS+=($!)
  else
    prompt_one "$short" "$herdr_name" "$kind" || FAIL=1
  fi
done
if [[ "$PARALLEL_PROMPT" -eq 1 && ${#PROMPT_PIDS[@]} -gt 0 ]]; then
  log "prompt-fanout waiting n=${#PROMPT_PIDS[@]}"
  set +e
  for pid in "${PROMPT_PIDS[@]}"; do
    wait "$pid"
    if [[ $? -ne 0 ]]; then
      FAIL=1
    fi
  done
  set -e
fi
log "prompt-fanout done mode=$PROMPT_MODE n=$PROMPT_N fail=$FAIL"
apply_prompt_statuses

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
# Grok: run_terminal_command background:true (do not close tab here):
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
