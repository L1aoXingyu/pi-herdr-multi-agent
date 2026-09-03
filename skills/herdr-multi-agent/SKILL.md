---
name: herdr-multi-agent
description: Launch a multi-model Herdr review fleet from Grok Build, wait with a background watchdog, and harvest VERDICT trailers. Use when the user wants multi-model TUI review via herdr, "launch N agents in herdr", "multi-agent review with visible panes", or prefers herdr TUI over headless spawn_subagent.
---

# /herdr-multi-agent — Multi-model Herdr fleet from Grok Build

Grok-owned copy (not a symlink to the pi skill). Parent is **Grok Build**. Fleet panes are still
whatever `herdr agent --kind` starts (default fleet: Pi + Cursor).

Use this when the user wants **visible interactive panes** in Herdr for independent parallel work
(review, investigation, design critique). Prefer this over headless `spawn_subagent` when TUI
visibility matters. Prefer `spawn_subagent` when only the final text result is needed, or Herdr
is unavailable.

This skill is an **out-of-band fleet launcher** (Grok orchestrates via `herdr` CLI). It is **not**
the official in-pane `herdr` skill (`HERDR_ENV=1` operator). Official `herdr` must not replace this
skill for fleets — that skill stops outside Herdr and defaults to splitting the current tab.

Aligned with **herdr ≥ 0.7.5** CLI semantics (see `herdr agent` / official `herdr` skill).
Tested against herdr 0.8.x. Requires a running Herdr server and `herdr` on `PATH`.

Lives at `~/.grok/skills/herdr-multi-agent`. Do not re-symlink to `~/.pi/agent/skills/`.

## Parent harness (Grok Build)

Grok has **no** pi `bg_run` / `bg-task`. Do not look for those tools.

| Need | Do this |
|---|---|
| Start the fleet | `run_terminal_command` → `bash "$SKILL_DIR/launch.sh" ...` |
| Wait for the fleet | `run_terminal_command` with `background: true` → `bash "$SKILL_DIR/watchdog.sh" --outdir ...`. Never foreground-poll. Completion wakes this turn; then `get_command_or_subagent_output` if you need the log. |
| Headless single helper | `spawn_subagent` — not this skill |
| In-pane Herdr ops | official `herdr` skill, and only if `HERDR_ENV=1` |


## Defaults

| Knob | Default |
|---|---|
| Workspace | focused workspace from `herdr workspace list`, else first workspace (`--workspace` override) |
| CWD | current project root |
| Outdir | `/tmp/herdr-multi-<slug>/` |
| Verdict marker | `VERDICT:` |
| Watchdog deadline | 40 minutes |
| Models | **`fleet.defaults` (usual six below)** when the user does not name models |
| Auto-close review tab | **on** after main-agent synthesis (see Cleanup) |
| Agent kind | per-agent from fleet (`pi` default; `cursor:` etc. for mixed fleets). Global `--kind` is the default only. Discover kinds via `herdr agent`. |

### Usual six models (default / daily fleet)

Source of truth: `$SKILL_DIR/fleet.defaults` (edit locally or pass `--fleet-file`).

When the user does **not** specify models/names (or says "the usual six" / "the usual five" /
"the usual four" / "the usual seven" / "the usual nine" / "the usual eight" / "default agents" / "daily fleet"), launch exactly this fleet:

| Name | Kind | Model |
|---|---|---|
| `gpt56sol` | `cursor` | `gpt-5.6-sol-xhigh` (via cursor-cli `agent`/`cursor-agent`) |
| `dsv4flash` | `pi` | `siliconflow/deepseek-ai/DeepSeek-V4-Flash:max` |
| `glm53` | `pi` | `siliconflow/zai-org/GLM-5.3:max` |
| `fable51` | `cursor` | `claude-fable-5-1-thinking-high` (via cursor-cli `agent`/`cursor-agent`) |
| `k3max` | `cursor` | `kimi-k3-max` (via cursor-cli `agent`/`cursor-agent`) |
| `g38flash` | `cursor` | `gemini-3.8-flash-high` (via cursor-cli `agent`/`cursor-agent`) |

### Full seven models (heavy fleet)

When the user says "the usual eleven" / "the usual ten" / "full fleet" / "heavy fleet" / "fleet.full", pass:

```bash
--fleet-file "$SKILL_DIR/fleet.full"
```

Adds back opencode-go `mimopro` on top of the six.
Daily Go seat is none (`hy3` and OpenCode Go `glm53` dropped: quota exhausted). Heavy Go seat is `mimopro` only.
No OpenRouter seat (`oxalpha` dropped: stealth/ox-alpha unusable).
SiliconFlow daily seats are `dsv4flash` (V4-Flash-0731; public id `deepseek-ai/DeepSeek-V4-Flash`) and `glm53` (`zai-org/GLM-5.3:max`).
No Antigravity seat (`g37flash` dropped). Cursor Gemini seat is `g38flash` (`gemini-3.8-flash-high`).
`oxalpha`, `hy3`, `glm52`, `k27code`, `dsv4pro`, `dsflash`, `dots3`, and `g37flash` are out of both fleets.
Kimi K3 is cursor-cli only (`k3max`); opencode-go `k3` is out of both fleets.
Phrase map: **usual six = defaults** (legacy: usual five / four / seven / eight / nine); **heavy seven = fleet.full** (legacy: usual six / seven / eight / nine / eleven / ten).

Fleet line formats:
- `name=provider/model[:thinking]` → kind `pi`
- `name=kind:model` → herdr kind prefix when `kind` is a known agent kind (e.g. `fable51=cursor:claude-fable-5-1-thinking-high`)

**Cursor dependency / security:** default fleet includes four cursor agents (`gpt56sol`, `fable51`, `k3max`, `g38flash`). Requires
`cursor-agent` on PATH (herdr's canonical executable) and a logged-in Cursor account. Launch exports
uppercase `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY`=`http://127.0.0.1:37890` in that pane (Cursor/Node
ignores lowercase `http_proxy`), then `herdr agent start --kind cursor`. Launch uses `--trust --force`
(= UI **Run Everything**): shell/tools auto-approve unless explicitly denied. Same blast radius
as unsupervised pi reviewers with full tools — intentional for unattended mixed fleets.
Missing cursor CLI when the fleet lists cursor entries fails preflight hard (unless
`--skip-model-preflight`).

Override names/models when the user specifies others. Keep **stable short agent names**
that stay unique after namespacing (see Name rules). If a default name collides with a live agent,
prefix once (e.g. `r2-gpt56sol`) rather than reusing the live name.

## Herdr CLI semantics (absorb from official skill)

### Lifecycle states

| Status | Meaning for this skill |
|---|---|
| `working` | Agent is busy; keep waiting |
| `idle` | Ready for input; tab has been **seen** in focused Herdr UI |
| `done` | Same underlying idle after **unseen** background work finishes. CLI reads do **not** mark seen. Treat as terminal for fleet wait (same as `idle`) |
| `blocked` | Approval/question UI. Terminal-ish for wait, but **not** a clean verdict — inspect `agent get` / `agent read`, steer if needed, do **not** auto-close |
| `unknown` | Present but unclassified. **Do not** treat as complete |
| `missing` | Name gone from `agent list` (exited/replaced). Treat as failed unless harvest already has verdict |

### Name rules (herdr 0.7.x)

Live agent names must match:

```text
^[a-z][a-z0-9_-]{0,31}$
```

- Start with a **letter**, max **32** chars total.
- Unique among live agents.
- A name follows the current pane occupant and clears when that agent exits/is replaced.
- This skill namespaces as `<session-prefix>-<short>` (recorded as `herdr_name`). Both short and
  full `herdr_name` must satisfy the regex after sanitization. Prefer short labels (`rev`, `r1`)
  so `herdr_name` stays ≤32.

Targets for agent commands: **unique live name** or **pane id hosting the agent** — not terminal ids
or bare kind labels.

### Read sources (prefer agent surface)

Prefer agent commands when an agent occupies the pane:

```bash
herdr agent read <herdr_name> --source recent-unwrapped --lines 200
herdr agent get <herdr_name>
```

| Source | Use |
|---|---|
| `recent-unwrapped` | **Default for harvest** — soft wraps joined; best for transcripts |
| `recent` | Rendered recent output including soft wraps |
| `visible` | Current viewport only |
| `detection` | Bottom-buffer snapshot used for agent detection |

Fall back to `herdr pane read <pane_id> ...` only when the agent name is missing or raw terminal
control is intentional.

**Alternate screen caveat (official):** if raising `--lines` still cannot recover a completed
response, the agent is likely on the terminal alternate screen; rows that leave it do not enter
Herdr host scrollback. Fallback order:

1. Session extract under `$OUTDIR/<short>/*.jsonl` (already done by watchdog)
2. Steer once: write complete response as Markdown under `$OUTDIR/<short>/verdict.md` and reply with path only; then read the file
3. Do **not** request file output in the initial fleet prompt (keeps the common path simple)

### Prompt / wait behavior (official + production)

Official:

- `herdr agent prompt <name> "..." --wait --timeout MS` waits for first settled `idle|done|blocked`
  (or explicit `--until`).
- From a non-working state, `--wait` requires an observed lifecycle change within **5s** or returns
  `agent_prompt_stalled`.
- `--wait` tracks lifecycle state, **not** individual turns.
- `herdr agent wait <name>` without `--until` uses the same settled defaults.

**This skill's production choice:**

- **Submit** with plain `herdr agent prompt` (no `--wait`) then poll `agent list` for
  `working|done|idle|blocked`. Reason: multi-model fanout + slow TUI paint made
  `agent_prompt_stalled` flaky when `--wait` raced startup. `launch.sh` runs that
  submit+poll per started agent **in parallel** after serial start (`--serial-prompt`
  restores one-by-one). Still never `prompt --wait`.
- **Fleet completion** uses `watchdog.sh` (name-based poll + VERDICT harvest), not N blocking
  `agent prompt --wait` calls in the main turn.
- **Single-agent recovery** may use `herdr agent wait <name> --until idle --until done --until blocked --timeout ...`
  or one enter-only nudge. Full re-prompt only if the composer still looks empty
  (cold title, no `Pasted text`, no prompt fingerprint). Title change means the
  first paste landed — do **not** stack another full prompt. Still require `VERDICT:`
  in harvest text.

### Layout primitives

- Workspace / tab / pane = topology. Pane commands = raw terminals. Agent commands = recognized coding agent in a pane.
- `agent start` requires an **existing available shell pane**; it never creates/splits layout.
- Available shell = interactive prompt, shell in foreground, no editor/agent/command running.
- Prefer `--no-focus` for background fleet work. Parse IDs from JSON (`.result.tab`, `.result.pane`, …).
- Split geometry: wide → `right`, tall/narrow → `down`; avoid repeated same-direction splits that make unusable strips.
- After `pane move`, use the new `.result.move_result.pane.pane_id` (old id is not a general target).

### Safety (official + fleet)

- Do not close workspaces/tabs/panes/sessions this run did not create unless the user explicitly asks.
- Never `herdr server stop` or kill the main Herdr process from this skill.
- Never print secrets from env/auth while launching.
- Prefer `--current` / explicit pane id / unique agent name — do not rely on another client's focused pane.
- CLI server errors: JSON on stderr, exit 1. Syntax errors: exit 2.

## Hard rules (from production failures)

1. **Serial `herdr agent start`** — never start all panes in one parallel blast; race → flaky ready state.
   Prompt fanout after start is parallel in `launch.sh` (see `--serial-prompt`).
2. **Pane must be an idle shell** before start. Fresh panes often report `agent_pane_busy` /
   "not an available shell". Fix: wait + `send-keys enter` + retry (up to ~60s).
3. **Do not hardcode pane ids across sessions** — always record the map from this launch
   (`name → herdr_name → pane_id → tab_id`) under outdir.
4. **Watchdog keys off agent `herdr_name`**, not pane id (pane id is fallback for raw read only).
5. **Prompt must force a machine-harvestable trailer** containing `VERDICT:` (or user override).
6. **Read-only by default** for review/investigation prompts unless the user explicitly wants writers.
7. **One review tab per run**. Do not reuse a live tab that still has working agents.
8. **Never print secrets** from env/auth while launching.
9. **Watchdog never closes panes/tabs.** Only the main agent closes, and only after synthesis
   (or explicit user cleanup), following the auto-close policy below.
10. **`done` counts as terminal** the same as `idle`; `unknown` does not; `blocked` is terminal-ish but keep tab.
11. **Harvest via `agent read --source recent-unwrapped` first**, then **assistant-only** session extract + `verdict_lib.py` strict trailer (not raw `VERDICT:` greps), then pane read.

## Helper script

Prefer the bundled helpers **in this skill directory** (the folder that contains this `SKILL.md`).
Resolve `SKILL_DIR` from that path — usually `~/.grok/skills/herdr-multi-agent`. Do **not** point
at the pi copy under `~/.pi/agent/skills/`.

```bash
# After reading this SKILL.md, set SKILL_DIR to its parent directory.
SKILL_DIR="<directory-containing-this-SKILL.md>"
bash "$SKILL_DIR/launch.sh" \
  --label "my-review" \
  --cwd "$PWD" \
  --outdir /tmp/herdr-multi-my-review \
  --prompt-file /tmp/herdr-multi-my-review/prompt.txt
  # omit --agent => fleet.defaults (usual six); optional --agent name=model ...
  # optional --agent gpt56sol=cursor:gpt-5.6-sol-xhigh  (mixed kind)
  # optional --agent glm53=siliconflow/zai-org/GLM-5.3:max
  # optional --agent fable51=cursor:claude-fable-5-1-thinking-high
  # optional --agent k3max=cursor:kimi-k3-max
  # optional --agent g38flash=cursor:gemini-3.8-flash-high
  # optional --fleet-file "$SKILL_DIR/fleet.full"  => heavy seven / fleet.full
  # optional --fleet-file PATH  => custom name=model list
  # optional --skip-model-preflight
  # optional --serial-prompt  => wait for each prompt accept before the next
  # optional --keep / --no-close  => do not auto-close after synthesis

# background: true on run_terminal_command (never foreground-poll; no bg_run):
bash "$SKILL_DIR/watchdog.sh" --outdir /tmp/herdr-multi-my-review

# after main-agent consensus reply:
bash "$SKILL_DIR/close.sh" --outdir /tmp/herdr-multi-my-review
```

`launch.sh` namespaces live herdr agent names as `<label>-<short>` (recorded as `herdr_name`
in `agents.json`) to avoid collisions with leftover agents. Short names stay stable for result files.

Harvest validation uses `$SKILL_DIR/verdict_lib.py` (strict trailer; ignores prompt echoes).

Default models live in `$SKILL_DIR/fleet.defaults` (edit, or override with `--agent` /
`--fleet-file`). They are **examples** — every model id must already work in the caller's pi config.

If the helper is missing or fails, follow the manual SOP below (same semantics).

## Manual SOP

### 0. Preflight

```bash
herdr status
herdr agent          # kinds + subcommands (installed binary is authority)
herdr agent list
herdr workspace list
```

- Confirm herdr server is running and protocol-compatible (`herdr --version`, expect ≥ 0.7.5 ideas above).
- Pick a free workspace (usually the project workspace).
- Choose a fresh `--label` and outdir. Create outdir and write `prompt.txt` first.
- Sanitize names so full `herdr_name` matches `^[a-z][a-z0-9_-]{0,31}$`.

### 1. Write the prompt

Put the full task in `$OUTDIR/prompt.txt`. Required trailer shape:

```text
... task body ...

End with:

VERDICT: ...
RISKS: ...
REQUIRED_FIXES: ...   # or N/A
CONFIDENCE: low|medium|high
```

For skill/code reviews, add at the top:

```text
READ-ONLY REVIEW — do not edit files, do not run long jobs, do not start servers.
```

Do **not** ask every agent to write a verdict file up front; that is a recovery path only.

### 2. Create tab + N panes

```bash
WS=<workspace_id>
CWD=<project_root>
TAB_JSON=$(herdr tab create --workspace "$WS" --cwd "$CWD" --label "<label>" --no-focus)
ROOT=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])' <<<"$TAB_JSON")
TAB_ID=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["tab"]["tab_id"])' <<<"$TAB_JSON")
```

Split to N panes (example N=5). Prefer alternating `right`/`down` from the newest usable parent;
avoid five pure vertical strips:

```bash
P0=$ROOT
P1=$(herdr pane split --pane "$P0" --direction right --ratio 0.5 --cwd "$CWD" --no-focus \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
P2=$(herdr pane split --pane "$P0" --direction down  --ratio 0.5 --cwd "$CWD" --no-focus \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
P3=$(herdr pane split --pane "$P1" --direction down  --ratio 0.5 --cwd "$CWD" --no-focus \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
P4=$(herdr pane split --pane "$P2" --direction right --ratio 0.5 --cwd "$CWD" --no-focus \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["pane"]["pane_id"])')
```

For other N: build a simple cascade of `right`/`down` splits; save the ordered pane list.
Always pass `--cwd` and `--no-focus`.

### 3. Start Pi on each pane (serial, with ready-retry)

For each `short|herdr_name|pane|model`:

```bash
# nudge shell — must be available interactive shell
herdr pane send-keys "$pane" enter 2>/dev/null || true
sleep 1
# pi (default)
herdr agent start "$herdr_name" --kind pi --pane "$pane" --timeout 180000 -- \
  --model "$model" \
  --session-dir "$OUTDIR/$short" \
  --name "$herdr_name"

# cursor: if 127.0.0.1:37890 is listening, export uppercase proxy in this pane
# (split does not inherit tab --env; Mac Surge is :6152 — skip a dead :37890)
herdr pane run "$pane" export HTTPS_PROXY=http://127.0.0.1:37890 HTTP_PROXY=http://127.0.0.1:37890 ALL_PROXY=http://127.0.0.1:37890
herdr agent start "$herdr_name" --kind cursor --pane "$pane" --timeout 180000 -- \
  --model "$model" --trust --force
```

Notes:

- `agent start` returns only after Herdr detects the expected agent and considers it ready (default
  start timeout 30s if you omit `--timeout`; this skill uses up to 180s, CLI max 300s).
- Pass **kind-native** args only after `--` for `agent start` (pi: `--session-dir`/`--name`; cursor: `--model`/`--trust`/`--force`). Do not `pane run cursor-agent-proxy` — that returns before the TUI composer exists and `herdr agent prompt` dumps into the PTY.
- Cursor `--force` (= `--yolo` / UI "Run Everything") is required for unattended fleets; `--trust` alone
  still blocks on shell allowlist prompts. This is intentional blast-radius for mixed default fleets.
- Mixed fleets are supported: each row in `agents.json` carries its own `kind`.
- Prompt recovery is **kind-aware**: pi never re-pastes the full prompt on idle; non-pi sends an
  enter-only nudge. Full re-prompt only if the composer still looks empty (default `Cursor Agent`
  title, no `Pasted text`, no ROLE/ONLY fingerprint). Title change or a paste marker means the
  first submit landed — do **not** stack another full prompt. After that enter, landed+idle is
  success; watchdog owns the wait. Source of truth: `fleet_lib.prompt_already_landed` /
  `nonpi_prompt_policy`. Harvest unwraps narrow-pane soft wraps before scoring `VERDICT:`.
- On `agent_pane_busy` / non-zero exit: wait 2–5s, send `enter` again, retry up to ~12 times (~60s).
- Do **not** proceed to prompt until start succeeds and `herdr agent list` shows that name as
  `idle` or `done` (optionally `herdr agent wait "$herdr_name" --until idle --until done --timeout 30000`).
- Persist mapping immediately to `$OUTDIR/agents.json`:

```json
[{
  "name": "gpt56sol",
  "herdr_name": "my-review-gpt56sol",
  "pane_id": "w5:pX",
  "tab_id": "w5:t9",
  "model": "gpt-5.6-sol-xhigh",
  "kind": "cursor",
  "start_status": "started"
},{
  "name": "fable51",
  "herdr_name": "my-review-fable51",
  "pane_id": "w5:pY",
  "tab_id": "w5:t9",
  "model": "claude-fable-5-1-thinking-high",
  "kind": "cursor",
  "start_status": "started"
}]
```

### 4. Prompt all agents

`launch.sh` fans these out concurrently (one job per started agent). Manual SOP
may submit sequentially; do not use `--wait` either way.

```bash
PROMPT=$(cat "$OUTDIR/prompt.txt")
for herdr_name in ...; do
  # no --wait (avoid agent_prompt_stalled races on fanout); poll list instead
  herdr agent prompt "$herdr_name" "$PROMPT" &
done
wait
```

Within ~10s, expect `agent_status=working` (or already settled `done`/`idle` if the model was instant).
If still stuck non-working without progress:

- `herdr agent read` / check `terminal_title_stripped`
- if landed (title left `Cursor Agent`, or `Pasted text #N`, or a ROLE/ONLY line): **enter only**
- if the composer still looks empty: one full `herdr agent prompt`, then enter
- if error is `agent_prompt_stalled`, treat as submit race: read; re-prompt only when empty, do not panic
- never stack a third full paste because herdr status stayed `idle`

### 5. Background watchdog (mandatory)

Launch `watchdog.sh` with `run_terminal_command` and `background: true` (do not foreground-poll
in the main turn; this harness has no `bg_run`). Watchdog must:

1. Poll `herdr agent list` every ~20s by **`herdr_name`**.
2. Terminal-ish statuses: `idle` | `done` | `blocked` | `missing` (after start failure skip).
   As soon as **all** names are terminal-ish, harvest and exit: zero when every successful agent
   has `VERDICT:`, non-zero partial otherwise. Never keep a settled fleet alive merely because a
   trailer is missing — the background command must exit so Grok wakes on completion. Structured
   provider/model errors (for example `429` quota exhaustion) are reported as `TERMINAL_FAILURE`.
3. On each harvest pass, prefer:
   ```bash
   herdr agent read "$herdr_name" --source recent-unwrapped --lines 250
   ```
   then session extract `$OUTDIR/<short>/*.jsonl` (Pi pane sessions), then `herdr pane read "$pane_id"` fallback.
4. Write `$OUTDIR/results/<short>.pane.txt` (agent/pane snapshot), optional `.extract.txt`,
   `$OUTDIR/results/summary.txt`, `$OUTDIR/results/check.json`, `$OUTDIR/results/progress.json`,
   and `$OUTDIR/watchdog_exit.json`.
5. On `blocked`, missing verdict, or explicit provider failure: snapshot, emit a partial summary,
   exit non-zero promptly, and do not invent a verdict. A non-zero background-command completion
   still wakes Grok to report/retry the partial fleet.
6. Deadline default 40m applies only while at least one agent remains non-terminal; honor user override.

Notify intent for the main agent (include outdir + auto-close reminder):

> Multi-model herdr review finished. Read `$OUTDIR/results/summary.txt` and synthesize consensus.
> Do not implement unless the user asked for implementation after review.
> Then apply herdr-multi-agent cleanup policy (default: close review tab after successful synthesis).

### 6. Synthesize (main agent)

After watchdog completion:

1. Read each verdict block from `$OUTDIR/results/summary.txt` (and pane/extract if needed).
2. Table: model → verdict → confidence → top risks.
3. Consensus + dissent.
4. Clear recommendation. Do **not** silently implement code from a review-only run.
5. If some agents `blocked` or missing `VERDICT:`, say so explicitly; offer steer/retry, do not close.
6. **Then run Cleanup (section 7)** — do not leave default review tabs forever.

### 7. Cleanup / auto-close policy

**Default `auto_close=true`.** Herdr does **not** auto-close on agent idle; this skill owns cleanup.

| When | Action |
|---|---|
| Watchdog finishes harvesting | **Do not close** (main agent still needs panes only if synthesis fails) |
| Main agent finished reading summary **and** posted consensus to the user | **Close the whole review tab** |
| User said `keep` / `keep panes` / `--keep` / `--no-close` | **Do not close**; say panes were kept |
| Any agent missing `VERDICT:`, status `blocked`, or watchdog deadline partial | **Do not close**; report which agents failed and leave tab for inspection |
| User later asks to clean up a kept/failed tab | Close that tab only |

Close granularity: **entire review tab** (preferred), not ad-hoc pane deletes:

```bash
TAB_ID=$(cat "$OUTDIR/tab_id.txt")   # written by launch.sh
bash "$SKILL_DIR/close.sh" --outdir "$OUTDIR"
# equivalent:
# herdr tab close "$TAB_ID"
```

Optional soft stop before close (best-effort, ignore errors):

```bash
for name in $(python3 -c 'import json; [print(r.get("herdr_name") or r["name"]) for r in json.load(open("'"$OUTDIR"'/agents.json"))]'); do
  herdr agent send-keys "$name" ctrl-c 2>/dev/null || true
done
```

**Never** close tabs/panes that are not part of this run's `tab_id` / `agents.json`.
Write `$OUTDIR/cleanup.json` after attempting close:
`{"closed": true|false, "reason": "...", "tab_id": "..."}`.

## Failure playbook

| Symptom | Action |
|---|---|
| `agent_pane_busy` at start | wait + enter + retry; confirm pane is bare shell via `pane read` / `agent` absent in list |
| start hangs past timeout | check pane output; close **that** pane only if this run created it, re-split one pane, retry that agent only |
| `agent_prompt_stalled` | lifecycle change not seen in 5s — `agent read`; enter if landed, re-prompt only if composer empty; do not use bare `--wait` for fleet submit |
| prompt accepted but stays idle | check title / `Pasted text`; if landed: enter only. If empty: one re-prompt + enter. Do **not** full-paste again after launch already failed-on-idle |
| `blocked` | `agent get` + `agent read`; answer approval UI via `agent send-keys` / prompt only if user policy allows; else leave tab and report |
| `unknown` status / `agent list` query failure | do not harvest as complete; retry until stall/deadline, then inspect Herdr health |
| watchdog exits partial after all idle/done | inspect `TERMINAL_FAILURE` / `NO_VALID_VERDICT`; replace quota/provider failures, or steer once "emit VERDICT block now" / write `$OUTDIR/<short>/verdict.md`; then rerun watchdog |
| name collision / invalid name | rename with shorter prefix; must match `^[a-z][a-z0-9_-]{0,31}$` |
| wrong cwd | always pass `--cwd` to tab create and pane split |
| harvest empty despite done | try `agent read --source recent-unwrapped`; then session jsonl extract; then file-fallback steer |
| CLI exit 2 | syntax/usage error — run `herdr agent` / subcommand help; do not retry blindly |
| accidental focus steal | ensure all splits/starts use `--no-focus` |

## Anti-patterns

- Parallel `herdr agent start` fanout
- Assuming previous run's pane ids still exist
- Watchdog matching on pane id only
- Watchdog or launch script closing the tab before main-agent synthesis
- Skipping verdict trailer in the prompt
- Full re-prompt of a cursor pane whose title already left `Cursor Agent` or that shows `Pasted text #N`
- Reusing a tab that still has `working` agents
- Leaving successful default review tabs open indefinitely (UI clutter)
- Closing unrelated tabs/panes while cleaning up
- Implementing review findings before user asks
- Using herdr multi-TUI when the user only needs headless text (use `spawn_subagent` instead)
- Treating `unknown` as success
- Keeping the watchdog alive after every agent is terminal just because a verdict is missing (suppresses the background-command completion wake)
- Fleet-wide `agent prompt --wait` as the only completion mechanism
- Relying on UI-focused pane instead of recorded pane_id / herdr_name
- `herdr server stop` or killing the Herdr main process from this workflow
- Hardcoding agent kinds without checking `herdr agent` when user asks non-Pi agents

## Minimal success criteria

- N agents started interactive in one labeled tab
- All received the same prompt and entered `working` (or settled with a real verdict)
- Watchdog produced `results/summary.txt` with N verdict blocks (or explicit timeout partial)
- Main agent reported consensus without inventing missing verdicts
- Cleanup policy applied: tab closed after successful synthesis, or explicitly kept with reason

## Relation to official `herdr` skill

| | Official `herdr` | This skill |
|---|---|---|
| Role | In-pane operator (`HERDR_ENV=1`) | External fleet orchestrator |
| Scale | Sibling helper / one command | N-model review tab |
| Wait | `prompt --wait` / `agent wait` | background `watchdog.sh` + VERDICT contract |
| Output | Free text (+ file fallback) | Forced `VERDICT:` trailer + outdir artifacts |
| Cleanup | Don't close what you didn't create | Own review tab; auto-close after synthesis |

Keep both installed. Do not replace this skill with the official one for multi-model review runs.
