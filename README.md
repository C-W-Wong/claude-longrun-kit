# claude-longrun-kit

**Self-healing for long-running Claude Code workflows — with an explicit per-pipeline opt-in switch.**

If you run multi-hour (10h+) agent workflows in [Claude Code](https://claude.com/claude-code), they die mid-flight: 5-hour usage-limit windows, transient API errors, a closed laptop, a killed session. This kit makes an interrupted pipeline **resume itself automatically at the next limit-reset window** — even when no Claude Code session is alive — while guaranteeing that pipelines you did *not* arm stay halted and wait for you.

## Install

```bash
git clone <this-repo> && cd claude-longrun-kit
./install.sh
```

- Idempotent — safe to re-run anytime; it **merges** into your existing `~/.claude/settings.json` (via `jq`) and never overwrites your settings.
- Dependencies: `jq`, `tmux`, and a logged-in `claude` CLI.
- macOS (launchd) and Linux (systemd user timer) supported.

## How it works — four layers

| # | Layer | Lives where | What it does |
|---|-------|-------------|--------------|
| 1 | **Circuit breaker** (convention) | each workflow script | An agent dying twice (usage limit / terminal API error) halts the run *cleanly at that unit* with partial state — failures never cascade. Claude authors this into scripts per the CLAUDE.md protocol. |
| 2 | **State file** | `~/.claude/long-run-state.json` | Single source of truth: status, project path, run ID, script path, resume protocol, and the **`autoResume` arm switch**. Written by Claude at launch and at every phase boundary / halt. |
| 3 | **Claude Code hooks** (2) | `~/.claude/settings.json` | `PostToolUse(Workflow)`: after every workflow launch, reminds the model to scaffold recovery and make the arm decision explicitly. `SessionStart`: every new session learns about an unfinished pipeline — armed → resumes autonomously; unarmed → informs you and waits. Hooks only inject context; they don't act on their own. |
| 4 | **OS heartbeat** | launchd / systemd timer | Fires at the usage-limit reset grid (+6 min). If an **armed** pipeline is halted **and no `claude` process is alive**, it spawns a recovery session inside tmux (`tmux attach -t claude-longrun` to watch). This is the layer that survives session death and reboots — something Claude Code hooks alone cannot do. |

A protocol section appended to `~/.claude/CLAUDE.md` teaches Claude the rest: when to arm (only when the user explicitly asks for unattended execution), how to treat the working tree on resume (keep it if the halt hit verify/commit; restore if an implementer died mid-edit), and how to resume (same session → workflow journal `resumeFromRunId`; new session → drop already-completed units and relaunch fresh).

## Controllability (the point)

Auto-resume is **opt-in per pipeline**, never global:

- Tell Claude "make this run self-healing / keep it running unattended" when launching → it sets `autoResume: true`.
- Say nothing → `autoResume: false`: a halt stays halted; the next session you open will *tell* you about it and await instructions.

Manual override anytime:

```bash
longrun status    # inspect the current pipeline state
longrun arm       # enable auto-resume for it
longrun disarm    # halts stay halted until you act
longrun done      # mark finished — silences every layer
longrun log       # tail the OS heartbeat log
```

## Configure your reset grid

Usage-limit windows reset on a fixed 5-hour grid that depends on your account/timezone. When you hit a limit, the error says e.g. `resets 4pm` — your grid is that hour ± 5h steps (default here: 02/07/11/16/21 local, firing at :06).

- macOS: edit `launchd.plist.template`, re-run `./install.sh`
- Linux: edit `systemd/claude-longrun-heartbeat.timer`, re-run `./install.sh`

## Security notes

- The OS-spawned recovery session runs `claude --dangerously-skip-permissions` by default — unattended resume can't stop at permission prompts. Override via env var before install, or edit `hooks/long-run-recovery-launch.sh`: set `CLAUDE_LONGRUN_PERM_FLAGS` (e.g. `--permission-mode acceptEdits`). **Only arm pipelines you trust to run unattended.**
- The heartbeat acts only when *all* of these hold: state file says `running` + `autoResume: true` + no live `claude` process + not already locked. Everything it does is logged to `~/.claude/long-run-heartbeat.log`.

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
hooks/longrun                        user control CLI
claude-md-longrun-section.md         protocol appended to ~/.claude/CLAUDE.md
launchd.plist.template               macOS scheduler
systemd/                             Linux scheduler (service + timer)
```

## License

MIT
# claude-longrun-kit
