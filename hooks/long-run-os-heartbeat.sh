#!/bin/bash
# OS-level heartbeat (launchd, fires at usage-limit reset grid +6min).
# Auto-resumes ONLY pipelines explicitly armed with autoResume:true in the state file.
# Unarmed pipelines are never touched - they stay halted until the user acts.
set -u
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin"
F="$HOME/.claude/long-run-state.json"
LOG="$HOME/.claude/long-run-heartbeat.log"
LOCK="$HOME/.claude/long-run-heartbeat.lock"
exec >>"$LOG" 2>&1
ts() { date "+%F %T"; }
[ -f "$F" ] || exit 0
jq -e . "$F" >/dev/null 2>&1 || { echo "$(ts) state file invalid JSON - skip"; exit 0; }
[ "$(jq -r '.status' "$F")" = "running" ] || exit 0
[ "$(jq -r '.autoResume // false' "$F")" = "true" ] || { echo "$(ts) pipeline not armed - skip"; exit 0; }
# liveness: if any interactive claude CLI is already running, its in-session heartbeat owns recovery
if pgrep -fl "claude" | grep -vE "long-run|tmux|grep|Claude.app" | grep -q "claude"; then
  echo "$(ts) live claude process found - skip"; exit 0
fi
if ! mkdir "$LOCK" 2>/dev/null; then echo "$(ts) lock held - skip"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
echo "$(ts) no live session + armed pipeline halted -> spawning recovery session in tmux"
tmux kill-session -t claude-longrun 2>/dev/null
tmux new-session -d -s claude-longrun "bash $HOME/.claude/hooks/long-run-recovery-launch.sh"
echo "$(ts) spawned tmux session 'claude-longrun' (attach: tmux attach -t claude-longrun)"
