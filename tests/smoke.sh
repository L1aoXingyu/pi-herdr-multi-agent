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

bash -n "$SKILL/launch.sh"
bash -n "$SKILL/watchdog.sh"
bash -n "$SKILL/close.sh"
pass "bash -n scripts"

# fleet.defaults parses to >=1 name=model lines
mapfile -t LINES < <(grep -v '^\s*#' "$SKILL/fleet.defaults" | grep -v '^\s*$' || true)
[[ ${#LINES[@]} -ge 1 ]] || fail "fleet.defaults has no entries"
for line in "${LINES[@]}"; do
  [[ "$line" == *=* ]] || fail "bad fleet line: $line"
done
pass "fleet.defaults (${#LINES[@]} agents)"

# launch.sh --help works and mentions fleet-file
help_out=$("$SKILL/launch.sh" --help)
grep -q -- '--fleet-file' <<<"$help_out" || fail "launch help missing --fleet-file"
grep -q -- '--agent' <<<"$help_out" || fail "launch help missing --agent"
pass "launch.sh --help"

# package.json declares skills
python3 - <<PY
import json
from pathlib import Path
pkg = json.loads(Path("$ROOT/package.json").read_text())
assert pkg.get("name") == "pi-herdr-multi-agent"
assert "./skills" in pkg.get("pi", {}).get("skills", []) or "skills" in pkg.get("pi", {}).get("skills", [])
print("OK: package.json pi.skills")
PY

# SKILL.md should not hardcode user global skill path as the only option
if grep -n '\$HOME/.pi/agent/skills/herdr-multi-agent' "$SKILL/SKILL.md"; then
  fail "SKILL.md still hardcodes \$HOME/.pi/agent/skills/herdr-multi-agent"
fi
pass "SKILL.md uses skill-relative paths"

# launch load_fleet_file path via dry missing-args
set +e
out=$("$SKILL/launch.sh" 2>&1)
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "launch with no args should fail"
grep -qi 'missing required args\|Usage:' <<<"$out" || fail "expected usage on missing args"
pass "launch.sh validates args"

echo "ALL_SMOKE_OK"
