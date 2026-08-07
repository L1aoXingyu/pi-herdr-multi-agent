# pi-herdr-multi-agent

Multi-model **interactive Pi TUI** fleets inside [Herdr](https://github.com/herdrdev/herdr), packaged as a [pi](https://pi.dev) skill.

Launch N visible Pi panes in one labeled tab, give them the same prompt, wait with a background watchdog, harvest machine-readable `VERDICT:` blocks, synthesize consensus in the main agent, then auto-close the review tab.

Prefer this over headless `pi-subagents` when **TUI visibility** matters. Prefer headless subagents when you only need the final text.

## Requirements

- [pi](https://pi.dev) coding agent
- [Herdr](https://github.com/herdrdev/herdr) **≥ 0.7.5** (`herdr` on `PATH`, server running) — tested on 0.8.x
- Model providers already configured in your pi auth / `models.json`

## Install

```bash
pi install git:github.com/L1aoXingyu/pi-herdr-multi-agent
```

Restart pi (or start a new session) so the skill is discovered. Invoke with `/skill:herdr-multi-agent` or by asking for a multi-model Herdr review.

Local checkout:

```bash
pi install /absolute/path/to/pi-herdr-multi-agent
```

## What you get

| File | Role |
|------|------|
| `skills/herdr-multi-agent/SKILL.md` | Agent SOP (launch → wait → harvest → synthesize → close) |
| `launch.sh` | Create tab, split panes, serial `agent start`, prompt fanout |
| `watchdog.sh` | Name-based poll + `VERDICT:` harvest (never closes tabs) |
| `close.sh` | Close the owned review tab after main-agent synthesis |
| `fleet.defaults` | Example default model list (`name=provider/model[:thinking]`) |

## Quick start (operator / agent)

```bash
SKILL_DIR="$(pi list 2>/dev/null | true)"  # or path to skills/herdr-multi-agent
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

# background wait (do not foreground-poll in the main agent turn):
bash "$SKILL_DIR/watchdog.sh" --outdir "$OUTDIR"

# after reading results/summary.txt and posting consensus:
bash "$SKILL_DIR/close.sh" --outdir "$OUTDIR"
```

## Default fleet

Shipped `fleet.defaults` is an **example** multi-model set. Override it:

1. Edit `skills/herdr-multi-agent/fleet.defaults`, or
2. Pass `--fleet-file PATH`, or
3. Pass one or more `--agent name=provider/model[:thinking]`

Every model id must already work with your pi install. There is no credential bundling in this package.

## Design notes (production hard rules)

- **Serial** `herdr agent start` — parallel start races flaky shell readiness
- Pane must be an **available shell** before start (enter + retry)
- Prompt **without** `herdr --wait` on fleet fanout (avoids `agent_prompt_stalled`); completion is the watchdog
- Watchdog keys off **agent name**, harvests `agent read --source recent-unwrapped` first
- Terminal statuses: `idle` / `done` / `blocked` / `missing` — **not** `unknown`
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
    summary.txt        # harvested VERDICT blocks
    <short>.pane.txt
    <short>.extract.txt
  cleanup.json         # written by close.sh
```

## Safety

- Do not close workspaces/tabs/panes this run did not create
- Never `herdr server stop` from this workflow
- Never print secrets from env/auth while launching
- Review-only prompts are read-only unless the user explicitly wants writers

## License

MIT
