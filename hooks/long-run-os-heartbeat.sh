#!/bin/bash
# OS-level heartbeat (launchd/systemd, fires every 30 min - no per-machine schedule config).
# Auto-resumes ONLY pipelines explicitly armed with autoResume:true in the state file.
# Universal timing: when a run halts on a usage limit, the session records the exact reset
# time (nextResetEpoch) in the state file; this script just waits for it. Unarmed pipelines
# are never touched.
set -u
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
F="$HOME/.claude/long-run-state.json"
LOG="$HOME/.claude/long-run-heartbeat.log"
LOCK="$HOME/.claude/long-run-heartbeat.lock"
STALE_SECS=5400   # spawned recovery session with no state-file progress for 90 min = stuck
exec >>"$LOG" 2>&1
ts() { date "+%F %T"; }
[ -f "$F" ] || exit 0
jq -e . "$F" >/dev/null 2>&1 || { echo "$(ts) state file invalid JSON - skip"; exit 0; }
[ "$(jq -r '.status' "$F")" = "running" ] || exit 0
[ "$(jq -r '.autoResume // false' "$F")" = "true" ] || exit 0

now=$(date +%s)
# Gate 1: honor the recorded usage-limit reset time, if any
nre=$(jq -r '.nextResetEpoch // empty' "$F")
if [ -n "$nre" ] && [ "$now" -lt "$nre" ]; then
  echo "$(ts) waiting for usage-limit reset (in $(( (nre - now) / 60 )) min) - skip"; exit 0
fi

# Gate 2: a previously spawned recovery session - skip while it makes progress, kill if stuck
if tmux has-session -t claude-longrun 2>/dev/null; then
  mt=$(stat -f %m "$F" 2>/dev/null || stat -c %Y "$F" 2>/dev/null || echo "$now")
  if [ $(( now - mt )) -lt "$STALE_SECS" ]; then
    echo "$(ts) recovery session alive and state fresh - skip"; exit 0
  fi
  echo "$(ts) recovery session stuck (no state progress >90min) - killing it for respawn"
  tmux kill-session -t claude-longrun 2>/dev/null
  sleep 3
fi

# Gate 3: any OTHER live claude session owns recovery itself (never interfere with user sessions)
if pgrep -fl "claude" | grep -vE "long-run|tmux|grep|Claude.app" | grep -q "claude"; then
  echo "$(ts) live claude process found - skip"; exit 0
fi

if ! mkdir "$LOCK" 2>/dev/null; then echo "$(ts) lock held - skip"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
echo "$(ts) armed pipeline halted, reset passed, no live session -> spawning recovery in tmux"
tmux new-session -d -s claude-longrun "bash $HOME/.claude/hooks/long-run-recovery-launch.sh"
echo "$(ts) spawned tmux session 'claude-longrun' (attach: tmux attach -t claude-longrun)"
