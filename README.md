# pi-herdr-multi-agent (`grok` branch)

This branch is the **Grok Build** parent-harness variant of the same skill.
Pi `main` is frozen at tag `pi-2026-09-05`. Do not merge this branch into `main`
as a silent replace — parent wait tools and prompt recovery differ. Further
fleet work is this `grok` branch plus the Cursor Agent overlay.

Launch N visible agent panes in one labeled Herdr tab, give them the same prompt,
wait with a background watchdog, harvest machine-readable `VERDICT:` blocks,
synthesize consensus in the **Grok** parent, then auto-close the review tab.

Prefer this over headless `spawn_subagent` when **TUI visibility** matters.
Prefer `spawn_subagent` when you only need the final text.

## Requirements

- [Grok Build](https://grok.com) CLI (parent orchestrator)
- [Herdr](https://github.com/herdrdev/herdr) **≥ 0.7.5** (`herdr` on `PATH`, server running) — tested on 0.8.x
- `python3` and `bash` on `PATH` (scripts avoid bash-4-only `mapfile` / GNU `readlink -f`)
- Fleet pane kinds (default: Codex + Pi + Cursor) already logged in on this machine

## Install (Grok)

```bash
git clone -b grok git@github.com:L1aoXingyu/pi-herdr-multi-agent.git
ln -sfn "$(pwd)/pi-herdr-multi-agent/skills/herdr-multi-agent" ~/.grok/skills/herdr-multi-agent
```

Or add a worktree from an existing checkout:

```bash
git worktree add -b grok ../pi-herdr-multi-agent-grok origin/grok
ln -sfn /absolute/path/to/pi-herdr-multi-agent-grok/skills/herdr-multi-agent \
  ~/.grok/skills/herdr-multi-agent
```

Grok discovers `SKILL.md` from `~/.grok/skills/`. Restart the session so the skill list refreshes.

Pi parent-harness is frozen at `pi-2026-09-05` (do not keep dual-maintaining):

```bash
git checkout pi-2026-09-05
```

## What you get

| File | Role |
|------|------|
| `skills/herdr-multi-agent/SKILL.md` | Agent SOP (launch → wait → harvest → synthesize → close) |
| `launch.sh` | Create tab, split panes, serial `agent start`, parallel prompt fanout (`--serial-prompt` to disable) |
| `watchdog.sh` | Name-based poll + `VERDICT:` harvest; exits partial promptly on settled failures (never closes tabs) |
| `close.sh` | Close the owned review tab after main-agent synthesis |
| `fleet.defaults` | Author daily default — **usual six** (`name=provider/model[:thinking]` or `name=kind:model`) |
| `fleet.full` | Author heavy profile — **heavy seven** / max diversity |
| `fleet.example` | Copy-paste template for your own fleet |
| `fleet_lib.py` | Shared kind:model parse, preflight match, start args |
| `verdict_lib.py` | Strict `VERDICT:` trailer parse (shared by watchdog/close) |

## Quick start (operator / agent)

```bash
# Directory that contains SKILL.md (package checkout or pi git install path)
SKILL_DIR=/path/to/pi-herdr-multi-agent/skills/herdr-multi-agent
OUTDIR=/tmp/herdr-multi-my-review
mkdir -p "$OUTDIR"

cat >"$OUTDIR/prompt.txt" <<'EOF'
READ-ONLY REVIEW — do not edit files, do not run long jobs.

Review the change described below.
...

End with:

VERDICT: ...
RISKS: ...
REQUIRED_FIXES: ...
CONFIDENCE: low|medium|high
EOF

bash "$SKILL_DIR/launch.sh" \
  --label "my-review" \
  --cwd "$PWD" \
  --outdir "$OUTDIR" \
  --prompt-file "$OUTDIR/prompt.txt"
  # optional: --agent short=provider/model:thinking  (repeatable)
  # optional: --fleet-file ./my-fleet.txt
  # optional: --keep

# Grok parent: run_terminal_command background:true (never foreground-poll; no bg_run):
bash "$SKILL_DIR/watchdog.sh" --outdir "$OUTDIR"

# after reading results/summary.txt and posting consensus:
bash "$SKILL_DIR/close.sh" --outdir "$OUTDIR"
```

## Default fleet

Shipped `fleet.defaults` is the **author's usual six** (daily lean profile):

- anchors: Codex `gpt-6-astra:high` + Cursor `claude-fable-5-1-thinking-high`
- Codex seat: `gpt6astra=codex:gpt-6-astra:high`
- Cursor seats: `k3max=cursor:kimi-k3-max` and `g38flash=cursor:gemini-3.8-flash-high`
- no daily opencode-go seat; `hy3` and OpenCode Go `glm53` are out of both fleets (quota exhausted)
- no OpenRouter seat; `oxalpha` is out of both fleets (stealth/ox-alpha unusable)
- no Antigravity seat; `g37flash` is out of both fleets
- no Cursor Sol seat; `gpt56sol` is out of both fleets
- SiliconFlow daily seats: `dsv4flash` (V4-Flash-0731) + `glm53=siliconflow/zai-org/GLM-5.3:max`; `oxalpha`, `hy3`, `glm52`, `k27code`, `dsv4pro`, `dots3`, `g37flash`, and `gpt56sol` are out of both fleets.

Heavy / max-diversity **seven** lives in `fleet.full`:

```bash
bash "$SKILL_DIR/launch.sh" ... --fleet-file "$SKILL_DIR/fleet.full"
```

Both profiles **fail preflight** on machines without the required providers/CLIs
(missing `pi`, `codex`, or `agent`/`cursor-agent` when listed is a hard error, not a silent skip).
For third-party use:

1. Copy `skills/herdr-multi-agent/fleet.example` → your own file and edit, or
2. Pass `--fleet-file PATH` (including shipped `fleet.full`), or
3. Pass one or more `--agent name=provider/model[:thinking]` or `--agent name=kind:model`

Discover models with `pi --list-models`, `codex login status`, and (for Cursor) `agent --list-models`.
`launch.sh` preflights via shared `fleet_lib.py` (exact cursor id match; pi token match; Codex cache).
Override with `--skip-model-preflight` only if you know what you're doing.

Cursor rows start with `--trust --force` (UI **Run Everything**) so unattended fleets do not
block on shell allowlist prompts. Codex rows pass `--dangerously-bypass-approvals-and-sandbox`
and `--dangerously-bypass-hook-trust`. Treat both as full tool autonomy.

Mixed-kind example:

```bash
bash "$SKILL_DIR/launch.sh" ... \
  --agent gpt6astra=codex:gpt-6-astra:high \
  --agent fable51=cursor:claude-fable-5-1-thinking-high
```

There is no credential bundling in this package.

## Design notes (production hard rules)

- **Serial** `herdr agent start` — parallel start races flaky shell readiness
- Pane must be an **available shell** before start (enter + retry)
- Prompt **without** `herdr --wait` on fleet fanout (avoids `agent_prompt_stalled`); completion is the watchdog
- Watchdog keys off **agent name**, harvests `agent read --source recent-unwrapped` first
- Terminal statuses: `idle` / `done` / `blocked` / `missing` — **not** `unknown`
- Once every agent is terminal, watchdog exits immediately: success with all verdicts, partial otherwise; provider errors such as `429` are classified from Pi sessions
- Watchdog **never** closes tabs; `close.sh` runs only after main-agent synthesis (or `--force`)
- Live agent names: `^[a-z][a-z0-9_-]{0,31}$`, namespaced as `<label>-<short>`

## Relation to official Herdr skill

| | Official `herdr` skill | This package |
|---|---|---|
| Role | In-pane operator (`HERDR_ENV=1`) | External fleet orchestrator |
| Scale | Sibling helper / one command | N-model review tab |
| Wait | `prompt --wait` / `agent wait` | bg watchdog + `VERDICT:` contract |
| Cleanup | Don't close what you didn't create | Own review tab; auto-close after synthesis |

Keep both. Do not replace this skill with the official one for multi-model review runs.

## Outdir layout

```
/tmp/herdr-multi-<label>/
  prompt.txt
  agents.json          # short → herdr_name → pane_id → model
  policy.json          # auto_close, verdict marker, tab_id
  tab_id.txt
  skill_dir.txt
  results/
    summary.txt         # harvested VERDICT blocks / terminal failures
    check.json           # structured strict-verdict result
    runtime-status.json  # latest Herdr status by short agent name
    <short>.pane.txt
    <short>.extract.txt
  watchdog_exit.json    # ok/partial + watchdog exit code
  cleanup.json          # written by close.sh
```

## Safety

- Do not close workspaces/tabs/panes this run did not create
- Never `herdr server stop` from this workflow
- Never print secrets from env/auth while launching
- Review-only prompts are read-only unless the user explicitly wants writers

## Troubleshooting

| Symptom | Fix |
|---|---|
| `model preflight failed` | `pi --list-models`, then fix `--agent` / `--fleet-file` (or auth) |
| `prompt-file must contain 'VERDICT:'` | Add the harvest trailer to `prompt.txt` (see skill SOP) |
| `agent_pane_busy` | Normal; launch retries. If stuck, check pane is a bare shell |
| Watchdog exits partial | Inspect `TERMINAL_FAILURE` / `NO_VALID_VERDICT`; replace a failed model or steer once, then rerun watchdog |
| `close.sh` refuses | Partial run; inspect `results/summary.txt`, then `--force` if you still want to close |
| Orphan tab after crashed launch | `tab_id` in outdir / `launch_exit.json`; `close.sh --outdir ... --force` |

See `skills/herdr-multi-agent/SKILL.md` failure playbook for the full matrix.

## Changelog

### Unreleased (`grok` branch)

- Cursor seats: `herdr agent start --kind cursor` after exporting uppercase `HTTP(S)_PROXY=http://127.0.0.1:37890` in the pane (do not `pane run cursor-agent-proxy`)
- Add `glm53=siliconflow/zai-org/GLM-5.3:max` to both fleets; daily is usual six, heavy is seven
- Add `g38flash=cursor:gemini-3.8-flash-high` to both fleets; Cursor Gemini is `g38flash` (not agy)
- Switch Fable seat to `fable51=cursor:claude-fable-5-1-thinking-high` (short name cannot contain a dot)
- Drop `g37flash=agy:gemini-3.7-flash-high` from both fleets (Antigravity path); Cursor Gemini is `g38flash`
- Drop `oxalpha=openrouter/stealth/ox-alpha:max` from both fleets (OpenRouter stealth/ox-alpha unusable)
- Drop `hy3=opencode-go/hy3:max` from both fleets (OpenCode Go quota exhausted)
- Drop `glm53=opencode-go/glm-5.3:max` from both fleets (OpenCode Go quota exhausted)
- Parent harness is Grok Build: `run_terminal_command` + `background: true` (no pi `bg_run`)
- Cursor prompt recovery: `prompt_already_landed` / `nonpi_prompt_policy` — enter-only when the first paste already landed; no stacked full re-prompt
- `which_cursor_cli` rejects Grok's `~/.grok/bin/agent`; require `cursor-agent`
- Narrow-pane `VERDICT:` unwrap in `verdict_lib.py`; watchdog writes `progress.json` + `runtime-status.json`
- Unit tests: `skills/herdr-multi-agent/tests/test_prompt_landed.py`

### Unreleased (`main`)

- Cursor seats: `herdr agent start --kind cursor` after exporting uppercase `HTTP(S)_PROXY=http://127.0.0.1:37890` in the pane (do not `pane run cursor-agent-proxy`)
- Add `glm53=siliconflow/zai-org/GLM-5.3:max` to both fleets; daily is usual six, heavy is seven
- Add `g38flash=cursor:gemini-3.8-flash-high` to both fleets; Cursor Gemini is `g38flash` (not agy)
- Mixed-kind fleets: `name=kind:model` (e.g. Cursor via `cursor:…`); shared `fleet_lib.py` parse/preflight/start args
- Cursor default seats: `fable51=cursor:claude-fable-5-1-thinking-high`, `k3max=cursor:kimi-k3-max`, and `g38flash=cursor:gemini-3.8-flash-high` with `--trust --force` (Run Everything)
- Kind-aware prompt recovery (pi never re-pastes; non-pi enter-only nudge); hard-fail missing kind CLIs
- Dual fleet profiles: **usual six** `fleet.defaults` (daily) + **heavy seven** `fleet.full`
- No daily Go seat; heavy Go seat is `mimopro` only. No OpenRouter seat; no Antigravity seat; `oxalpha` / `hy3` / `glm52` / `k27code` / `dots3` / `g37flash` dropped
- Unit tests: `tests/test_fleet_lib.py`
- Exit the watchdog immediately with a partial result after every agent settles, preventing missing background completion notifications
- Classify terminal provider/model errors (including `429` quota exhaustion) from structured Pi session records
- Treat list-query failures as `unknown`, and keep `blocked` agents partial even if they emitted a verdict
- Persist structured status/exit artifacts; reject placeholder `VERDICT: ...` echoes

### 0.1.1

- Strict VERDICT harvest (`verdict_lib.py`) — rejects prompt-template echoes; prefers assistant session text
- Model preflight via `pi --list-models`; `--skip-model-preflight` escape hatch
- Fail-closed watchdog/close (skip `start_failed`; exit 1 if zero/partial valid verdicts)
- Watchdog stall detection + `results/progress.json`
- `herdr_name` length clamp fix; pass clamped name to `pi --name`
- Busy vs hard-fail start retries; prompt status no longer succeeds on perpetual `missing`/`unknown`
- Prompt must contain `VERDICT:`; `--force` clears stale results/verdicts
- Launch exit breadcrumb for orphan tabs; `--kind` override; bash3-portable row loading
- `fleet.example` + README troubleshooting

### 0.1.0

- Initial public skill package

## License

MIT
