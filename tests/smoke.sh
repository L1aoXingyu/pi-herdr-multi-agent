#!/usr/bin/env bash
# Offline smoke checks — no herdr server required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/herdr-multi-agent"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "OK: $*"; }

[[ -f "$SKILL/SKILL.md" ]] || fail "SKILL.md missing"
[[ -x "$SKILL/launch.sh" && -x "$SKILL/watchdog.sh" && -x "$SKILL/close.sh" ]] || fail "scripts not executable"
[[ -f "$SKILL/fleet.defaults" ]] || fail "fleet.defaults missing"
[[ -f "$SKILL/fleet.example" ]] || fail "fleet.example missing"
[[ -f "$SKILL/verdict_lib.py" ]] || fail "verdict_lib.py missing"

bash -n "$SKILL/launch.sh"
bash -n "$SKILL/watchdog.sh"
bash -n "$SKILL/close.sh"
pass "bash -n scripts"

# fleet.defaults parses to >=1 name=model lines
LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] && LINES+=("$line")
done < <(grep -v '^\s*#' "$SKILL/fleet.defaults" | grep -v '^\s*$' || true)
[[ ${#LINES[@]} -ge 1 ]] || fail "fleet.defaults has no entries"
for line in "${LINES[@]}"; do
  [[ "$line" == *=* ]] || fail "bad fleet line: $line"
done
pass "fleet.defaults (${#LINES[@]} agents)"

help_out=$("$SKILL/launch.sh" --help)
grep -q -- '--fleet-file' <<<"$help_out" || fail "launch help missing --fleet-file"
grep -q -- '--skip-model-preflight' <<<"$help_out" || fail "launch help missing --skip-model-preflight"
grep -q -- '--agent' <<<"$help_out" || fail "launch help missing --agent"
pass "launch.sh --help"

# prompt without VERDICT rejected
tmp=$(mktemp -d)
set +e
out=$("$SKILL/launch.sh" --label t --cwd "$ROOT" --outdir "$tmp/o" --prompt-file "$tmp/p.txt" \
  --agent a=x/y --skip-model-preflight 2>&1)
rc=$?
set -e
echo 'no marker' >"$tmp/p.txt"
set +e
out=$("$SKILL/launch.sh" --label t --cwd "$ROOT" --outdir "$tmp/o" --prompt-file "$tmp/p.txt" \
  --agent a=x/y --skip-model-preflight 2>&1)
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "launch should reject prompt without VERDICT"
grep -qi 'VERDICT' <<<"$out" || fail "expected VERDICT error"
pass "prompt VERDICT validation"

python3 - <<PY
import json
from pathlib import Path
pkg = json.loads(Path("$ROOT/package.json").read_text())
assert pkg.get("name") == "pi-herdr-multi-agent"
assert "./skills" in pkg.get("pi", {}).get("skills", []) or "skills" in pkg.get("pi", {}).get("skills", [])
print("OK: package.json pi.skills")
PY

if grep -n '\$HOME/.pi/agent/skills/herdr-multi-agent' "$SKILL/SKILL.md"; then
  fail "SKILL.md still hardcodes \$HOME/.pi/agent/skills/herdr-multi-agent"
fi
pass "SKILL.md uses skill-relative paths"

# unit tests
python3 "$ROOT/tests/test_verdict_lib.py"
pass "verdict_lib unit tests"

# name clamp unit (inline)
python3 - <<'PY'
import re
# replicate clamp invariants
def sanitize_token(s, max_len=32):
    s = s.strip().lower()
    s = re.sub(r"[^a-z0-9_-]+", "-", s)
    s = re.sub(r"-+", "-", s).strip("-")
    if not s: s = "agent"
    if not s[0].isalpha(): s = "a"+s
    return s[:max_len]
name_re = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
for prefix, short in [("verylonglabelprefixxxx", "alsolongshortname"), ("r", "a"*30), ("ab", "x"*30)]:
    short = sanitize_token(short, 30)
    budget = 32 - 1 - len(short)
    if budget >= 1:
        p = sanitize_token(prefix, budget)[:budget].rstrip("-") or "r"
        herdr = f"{p}-{short}"
    else:
        herdr = short[:32]
    herdr = herdr[:32]
    assert name_re.match(herdr), herdr
    assert len(herdr) <= 32, (herdr, len(herdr))
print("OK: name clamp invariants")
PY

echo "ALL_SMOKE_OK"
