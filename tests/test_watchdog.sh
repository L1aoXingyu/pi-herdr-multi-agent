#!/usr/bin/env bash
# Regression: a settled fleet with a provider failure must notify promptly by exiting partial.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCHDOG="$ROOT/skills/herdr-multi-agent/watchdog.sh"
BASH_BIN=${BASH_BIN:-/bin/bash}
[[ -x "$BASH_BIN" ]] || BASH_BIN=$(command -v bash)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out"
mkdir -p "$TMP/bin" "$OUT/results" "$OUT/good" "$OUT/limited"

cat >"$OUT/agents.json" <<'JSON'
[
  {"name":"good","herdr_name":"test-good","pane_id":"p1","start_status":"started"},
  {"name":"limited","herdr_name":"test-limited","pane_id":"p2","start_status":"started"},
  {"name":"never-started","herdr_name":"test-never-started","pane_id":"p5","start_status":"failed"}
]
JSON
cat >"$OUT/policy.json" <<'JSON'
{"verdict_marker":"VERDICT:","auto_close":true}
JSON
cat >"$OUT/good/verdict.md" <<'EOF'
VERDICT: ship
RISKS: none
REQUIRED_FIXES: N/A
CONFIDENCE: high
EOF
python3 - <<'PY' "$OUT/limited/session.jsonl"
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    "type": "message",
    "message": {
        "role": "assistant",
        "content": [],
        "stopReason": "error",
        "errorMessage": "429: Weekly usage limit reached",
    },
}) + "\n")
PY

cat >"$TMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "agent" && "${2:-}" == "list" ]]; then
  cat <<'JSON'
{"result":{"agents":[
  {"name":"test-good","pane_id":"p1","agent_status":"done"},
  {"name":"test-limited","pane_id":"p2","agent_status":"done"}
]}}
JSON
  exit 0
fi
# Reads can fail: verdict.md and the structured Pi session are the harvest sources.
exit 1
SH
chmod +x "$TMP/bin/herdr"

start=$SECONDS
set +e
PATH="$TMP/bin:$PATH" "$BASH_BIN" "$WATCHDOG" \
  --outdir "$OUT" --poll-sec 1 --stall-sec 30 --deadline-sec 30 >"$TMP/watchdog.log" 2>&1
rc=$?
set -e
elapsed=$((SECONDS - start))

[[ $rc -eq 1 ]] || { cat "$TMP/watchdog.log"; echo "expected partial rc=1, got $rc" >&2; exit 1; }
[[ $elapsed -lt 5 ]] || { cat "$TMP/watchdog.log"; echo "watchdog waited ${elapsed}s after fleet settled" >&2; exit 1; }
grep -q 'ALL_AGENTS_TERMINAL_PARTIAL' "$TMP/watchdog.log"
grep -q 'TERMINAL_FAILURE' "$OUT/results/summary.txt"
grep -q '"category": "rate_limit"' "$OUT/results/check.json"
python3 - <<'PY' "$OUT/watchdog_exit.json"
import json, sys
result = json.load(open(sys.argv[1]))
assert result.get("status") == "partial" and result.get("exit_rc") == 1, result
PY

echo "OK: terminal provider failure exits partial promptly (${elapsed}s)"

# A blocked agent remains partial even if stale/early output contains a verdict.
OUT_BLOCKED="$TMP/out-blocked"
mkdir -p "$OUT_BLOCKED/results" "$OUT_BLOCKED/blocked"
cat >"$OUT_BLOCKED/agents.json" <<'JSON'
[{"name":"blocked","herdr_name":"test-blocked","pane_id":"p3","start_status":"started"}]
JSON
cat >"$OUT_BLOCKED/blocked/verdict.md" <<'EOF'
VERDICT: ship
RISKS: none
REQUIRED_FIXES: N/A
CONFIDENCE: high
EOF
cat >"$TMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "agent" && "${2:-}" == "list" ]]; then
  echo '{"result":{"agents":[{"name":"test-blocked","pane_id":"p3","agent_status":"blocked"}]}}'
  exit 0
fi
exit 1
SH
chmod +x "$TMP/bin/herdr"
set +e
PATH="$TMP/bin:$PATH" "$BASH_BIN" "$WATCHDOG" \
  --outdir "$OUT_BLOCKED" --poll-sec 1 --stall-sec 30 --deadline-sec 30 >"$TMP/blocked.log" 2>&1
blocked_rc=$?
set -e
[[ $blocked_rc -eq 1 ]] || { cat "$TMP/blocked.log"; echo "blocked fleet unexpectedly succeeded" >&2; exit 1; }
grep -q 'BLOCKED_UI' "$OUT_BLOCKED/results/summary.txt"
grep -q '"status": "blocked"' "$OUT_BLOCKED/results/check.json"
echo "OK: blocked agent cannot produce a successful fleet result"

# A transient list-query failure is unknown, not missing/terminal; the next poll can recover.
OUT_TRANSIENT="$TMP/out-transient"
COUNTER="$TMP/list-count"
mkdir -p "$OUT_TRANSIENT/results" "$OUT_TRANSIENT/transient"
cat >"$OUT_TRANSIENT/agents.json" <<'JSON'
[{"name":"transient","herdr_name":"test-transient","pane_id":"p4","start_status":"started"}]
JSON
cat >"$OUT_TRANSIENT/transient/verdict.md" <<'EOF'
VERDICT: ship
RISKS: none
REQUIRED_FIXES: N/A
CONFIDENCE: high
EOF
cat >"$TMP/bin/herdr" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "agent" && "${2:-}" == "list" ]]; then
  count=0
  [[ -f "$HERDR_COUNTER" ]] && count=$(cat "$HERDR_COUNTER")
  count=$((count + 1))
  echo "$count" >"$HERDR_COUNTER"
  if [[ $count -eq 1 ]]; then
    exit 1
  fi
  echo '{"result":{"agents":[{"name":"test-transient","pane_id":"p4","agent_status":"done"}]}}'
  exit 0
fi
exit 1
SH
chmod +x "$TMP/bin/herdr"
start=$SECONDS
HERDR_COUNTER="$COUNTER" PATH="$TMP/bin:$PATH" "$BASH_BIN" "$WATCHDOG" \
  --outdir "$OUT_TRANSIENT" --poll-sec 1 --stall-sec 30 --deadline-sec 30 >"$TMP/transient.log" 2>&1
transient_elapsed=$((SECONDS - start))
grep -q 'transient=unknown' "$TMP/transient.log"
grep -q 'WATCHDOG_OK' "$TMP/transient.log"
[[ $transient_elapsed -ge 1 ]] || { cat "$TMP/transient.log"; echo "list failure was treated as terminal" >&2; exit 1; }
echo "OK: transient agent-list failure recovers on a later poll (${transient_elapsed}s)"

"$BASH_BIN" --version | head -n 1 | sed 's/^/OK: watchdog exercised with /'
