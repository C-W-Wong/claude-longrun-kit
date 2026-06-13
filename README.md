# claude-longrun-kit

**Self-healing for long-running Claude Code workflows — with an explicit per-pipeline opt-in switch.**

If you run multi-hour (10h+) agent workflows in [Claude Code](https://claude.com/claude-code), they die mid-flight: 5-hour usage-limit windows, transient API errors, a closed laptop, a killed session. This kit makes an interrupted pipeline **resume itself automatically at the next limit-reset window** — even when no Claude Code session is alive — while guaranteeing that pipelines you did *not* arm stay halted and wait for you.

## Install

### Step 0 — prerequisites

**Claude Code CLI** (skip if `claude --version` already works):

```bash
# macOS / Linux / WSL — official native installer
curl -fsSL https://claude.ai/install.sh | bash

# or via npm (needs Node 18+)
npm install -g @anthropic-ai/claude-code
```

Then run `claude` once in any folder and complete the login flow.

**jq and tmux** (the kit's only other dependencies — jq for all JSON handling, tmux to host the auto-spawned recovery session, which must be an interactive long-lived terminal app):

```bash
# macOS
brew install jq tmux

# Debian / Ubuntu
sudo apt-get install -y jq tmux
```

### Step 1 — install the kit

One-liner (downloads this repo and installs):

```bash
curl -fsSL https://raw.githubusercontent.com/C-W-Wong/claude-longrun-kit/main/install.sh | bash
```

Or clone first (nicer if you want `git pull && ./install.sh` updates later):

```bash
git clone https://github.com/C-W-Wong/claude-longrun-kit.git
cd claude-longrun-kit
./install.sh
```

Either way the installer is **idempotent** — safe to re-run anytime; it **merges** into your existing `~/.claude/settings.json` (via `jq`) and never overwrites your settings. macOS (launchd) and Linux (systemd user timer) supported; Windows isn't (WSL with systemd works).

What it installs: 5 scripts → `~/.claude/hooks/`, the `longrun` CLI → `~/.local/bin/` (make sure that's on your PATH), 2 hook entries → `~/.claude/settings.json`, a protocol section → `~/.claude/CLAUDE.md`, and the 30-min OS heartbeat (launchd/systemd).

### Step 2 — verify

```bash
longrun status                              # fresh install correctly says: no long-run state file
launchctl list | grep longrun               # macOS → com.claude.longrun-heartbeat
systemctl --user list-timers | grep longrun # Linux  → claude-longrun-heartbeat.timer
```

### Step 3 — use it

Launch your long task in Claude Code and add one sentence: **"make this run self-healing — auto-resume if it gets interrupted."** Claude then arms the pipeline (`autoResume: true`), and every interruption (usage limit, API error, killed session, reboot) heals itself. Say nothing → interruptions halt cleanly and wait for you. Control anytime with `longrun arm | disarm | done`.

## How it works — four layers

| # | Layer | Lives where | What it does |
|---|-------|-------------|--------------|
| 1 | **Circuit breaker** (convention) | each workflow script | An agent dying twice (usage limit / terminal API error) halts the run *cleanly at that unit* with partial state — failures never cascade. Claude authors this into scripts per the CLAUDE.md protocol. |
| 2 | **State directory** | `~/.claude/long-run-state/` | One JSON per pipeline (`<project>-<run-id>.json`) — multiple long runs are tracked side by side. Each entry holds status, project path, run ID, script path, resume protocol, and the **`autoResume` arm switch**. Written by Claude at launch and at every phase boundary / halt. A legacy single `long-run-state.json` migrates automatically. |
| 3 | **Claude Code hooks** (2) | `~/.claude/settings.json` | `PostToolUse(Workflow)`: after every workflow launch, reminds the model to scaffold recovery and make the arm decision explicitly. `SessionStart`: every new session learns about an unfinished pipeline — armed → resumes autonomously; unarmed → informs you and waits. Hooks only inject context; they don't act on their own. |
| 4 | **OS heartbeat** | launchd / systemd timer | Fires every 30 min — machine-agnostic, zero schedule config. If an **armed** pipeline is halted, the recorded reset time has passed, **and no `claude` process is alive**, it spawns a recovery session inside tmux (`tmux attach -t claude-longrun` to watch). This is the layer that survives session death and reboots — something Claude Code hooks alone cannot do. |

A protocol section appended to `~/.claude/CLAUDE.md` teaches Claude the rest: when to arm (only when the user explicitly asks for unattended execution), how to treat the working tree on resume (keep it if the halt hit verify/commit; restore if an implementer died mid-edit), and how to resume (same session → workflow journal `resumeFromRunId`; new session → drop already-completed units and relaunch fresh).

## Controllability (the point)

Auto-resume is **opt-in per pipeline**, never global:

- Tell Claude "make this run self-healing / keep it running unattended" when launching → it sets `autoResume: true`.
- Say nothing → `autoResume: false`: a halt stays halted; the next session you open will *tell* you about it and await instructions.

Manual override anytime:

```bash
longrun status            # list all pipelines (+ update notice if any)
longrun status <id>       # one pipeline in full
longrun arm    [id]       # enable auto-resume for it
longrun disarm [id]       # halts stay halted until you act
longrun done   [id]       # mark finished — silences every layer for it
longrun reopen [id]       # undo an accidental `done`: status back to running
longrun prune  [days]     # delete done pipelines untouched for >days (default 14)
longrun log    [n]        # tail the OS heartbeat log
longrun help              # full reference
```

`[id]` can be omitted while only one pipeline exists, and prefix matching works (`longrun arm cabinet`).

**Multiple pipelines**: every long run gets its own state entry, so several can be tracked at once — but recovery is deliberately **serialized**: each heartbeat pass revives at most ONE halted armed pipeline (oldest first), because parallel revivals would just race the same account's usage quota and re-halt each other. The rest queue for the following passes.

## Timing — universal by design

Usage-limit windows reset on a 5-hour grid that differs per account and timezone, so the kit never hardcodes it. Instead:

1. When a run halts on a limit, the error message names the exact reset time (`resets 4pm`). The Claude session records it in the state file as `nextResetEpoch` (the CLAUDE.md protocol instructs this).
2. The OS heartbeat fires every 30 minutes on every machine and simply waits until `nextResetEpoch` has passed before acting. Each premature firing exits in milliseconds.
3. No `nextResetEpoch` recorded (e.g. the session crashed before writing it)? The heartbeat just tries; if the spawned recovery session itself gets stuck on a still-exhausted limit, the stale-session guard kills and respawns it after 90 minutes of no progress.

Tunables (edit, then re-run `./install.sh`): firing interval — `StartInterval` in `launchd.plist.template` / `OnUnitActiveSec` in the systemd timer; stuck threshold — `STALE_SECS` in `hooks/long-run-os-heartbeat.sh`.

## Storage footprint — bounded by design

Nothing the kit writes grows without limit:

- **Heartbeat log** (`~/.claude/long-run-heartbeat.log`) is capped — each pass rotates it down to its last 500 lines once it passes `CLAUDE_LONGRUN_LOG_MAX_BYTES` (256 KB default).
- **Finished pipelines** are auto-pruned: the heartbeat deletes any `done` state file untouched for `CLAUDE_LONGRUN_DONE_RETAIN_DAYS` (14 by default; set `0` to keep history forever). This also keeps the per-pass scan — and `longrun status` — proportional to *active* pipelines, not your entire run history. Prune on demand with `longrun prune [days]`.

Both knobs are env vars read by `hooks/long-run-os-heartbeat.sh`; set them before install (or edit the defaults at the top of the script). CPU/power cost is negligible regardless: the heartbeat is a 30-min timer, not a daemon, and each idle pass exits in milliseconds.

## Security notes

- The OS-spawned recovery session runs `claude --dangerously-skip-permissions` by default — unattended resume can't stop at permission prompts. Override via env var before install, or edit `hooks/long-run-recovery-launch.sh`: set `CLAUDE_LONGRUN_PERM_FLAGS` (e.g. `--permission-mode acceptEdits`). **Only arm pipelines you trust to run unattended.**
- The heartbeat acts only when *all* of these hold for some pipeline entry: status `running` + `autoResume: true` + recorded reset time passed + no live `claude` process + no fresh recovery session + not already locked — and then it revives only that one entry. Everything it does is logged to `~/.claude/long-run-heartbeat.log`.

## Updates — notify-only, never automatic

The kit deliberately does **not** auto-update itself: the recovery session runs with skipped permission prompts, so silently executing fresh code from the network would be a supply-chain hole. Instead, a notify-only check (≤1 GitHub API call per day, 3s timeout, offline-silent) compares your installed commit with `main` and shows a one-line notice in `longrun status`, the heartbeat log, and the session-start context. Upgrading is always the same explicit command as installing:

```bash
curl -fsSL https://raw.githubusercontent.com/C-W-Wong/claude-longrun-kit/main/install.sh | bash
```

## Uninstall

```bash
# macOS
launchctl unload ~/Library/LaunchAgents/com.claude.longrun-heartbeat.plist
rm ~/Library/LaunchAgents/com.claude.longrun-heartbeat.plist
# Linux
systemctl --user disable --now claude-longrun-heartbeat.timer

rm ~/.claude/hooks/long-run-* ~/.claude/hooks/longrun ~/.local/bin/longrun
# then remove the two hook entries from ~/.claude/settings.json
# and the "Long-run recovery" section from ~/.claude/CLAUDE.md
```

## Files

```
install.sh                      one-command idempotent installer
hooks/long-run-launch-reminder.sh    PostToolUse(Workflow) hook
hooks/long-run-session-start.sh      SessionStart hook
hooks/long-run-os-heartbeat.sh       OS heartbeat (gate checks + tmux spawn)
hooks/long-run-recovery-launch.sh    runs inside tmux: starts the recovery claude session
hooks/long-run-update-check.sh       notify-only daily update check
hooks/longrun                        user control CLI
claude-md-longrun-section.md         protocol appended to ~/.claude/CLAUDE.md
launchd.plist.template               macOS scheduler
systemd/                             Linux scheduler (service + timer)
```

## License

MIT
# claude-longrun-kit
