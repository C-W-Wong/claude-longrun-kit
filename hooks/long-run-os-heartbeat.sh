#!/bin/bash
# OS-level heartbeat (launchd/systemd, every 30 min - no per-machine schedule config).
# Multi-pipeline: tracks every entry in ~/.claude/long-run-state/ and revives AT MOST
# ONE halted armed pipeline per pass (oldest-stalled first). Serialized on purpose:
# parallel recoveries would only race the shared usage quota and re-halt each other.
# Unarmed pipelines are never touched.
set -u
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
D="$HOME/.claude/long-run-state"
LEGACY="$HOME/.claude/long-run-state.json"
LOG="$HOME/.claude/long-run-heartbeat.log"
LOCK="$HOME/.claude/long-run-heartbeat.lock"
MARK="$D/.recovering"
STALE_SECS=5400   # recovery session with no state-file progress for 90 min = stuck
LOG_MAX_BYTES=${CLAUDE_LONGRUN_LOG_MAX_BYTES:-262144}    # cap the heartbeat log (256 KB default); keep the tail on overflow
DONE_RETAIN_DAYS=${CLAUDE_LONGRUN_DONE_RETAIN_DAYS:-14}  # prune done pipelines untouched for this many days (0 = keep forever)
# Rotate BEFORE redirecting: the log appends every pass, so without a cap it grows without bound.
if [ -f "$LOG" ]; then
  sz=$(stat -c %s "$LOG" 2>/dev/null || stat -f %z "$LOG" 2>/dev/null || echo 0)
  [ "$sz" -gt "$LOG_MAX_BYTES" ] && { tail -n 500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; }
fi
exec >>"$LOG" 2>&1
ts() { date "+%F %T"; }
# mtime in epoch seconds, GNU-first then BSD: on Linux `stat -f %m` does NOT fail
# cleanly (it prints filesystem info), so the BSD form must come last, never first.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo "$now"; }
bash "$HOME/.claude/hooks/long-run-update-check.sh" 2>/dev/null || true
if [ -f "$LEGACY" ]; then
  mkdir -p "$D"
  slug=$(basename "$(jq -r '.project // "pipeline"' "$LEGACY" 2>/dev/null)" 2>/dev/null) || slug=pipeline
  mv "$LEGACY" "$D/${slug}.json" && echo "$(ts) migrated legacy state file to $D/${slug}.json"
fi
[ -d "$D" ] || exit 0
now=$(date +%s)

# Retention: drop done pipelines whose state file hasn't changed in DONE_RETAIN_DAYS.
# Keeps the hot loops below (and `longrun status`) proportional to ACTIVE pipelines, not all history.
if [ "$DONE_RETAIN_DAYS" -gt 0 ] 2>/dev/null; then
  cutoff=$(( now - DONE_RETAIN_DAYS * 86400 ))
  for f in "$D"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.status' "$f" 2>/dev/null)" = "done" ] || continue
    mt=$(mtime "$f")
    [ "$mt" -lt "$cutoff" ] && rm -f "$f" && echo "$(ts) pruned done pipeline state (untouched >${DONE_RETAIN_DAYS}d): $(basename "$f")"
  done
fi

# A recovering marker without its tmux session = finished/crashed recovery; clear it
if [ -f "$MARK" ] && ! tmux has-session -t claude-longrun 2>/dev/null; then rm -f "$MARK"; fi

# Existing recovery session: skip while it makes progress, kill if stuck
if tmux has-session -t claude-longrun 2>/dev/null; then
  tgt=$(cat "$MARK" 2>/dev/null || true)
  ref="$D/${tgt}.json"
  [ -f "$ref" ] || ref=$(ls -t "$D"/*.json 2>/dev/null | head -1)
  mt=$(mtime "$ref")
  if [ $(( now - mt )) -lt "$STALE_SECS" ]; then
    echo "$(ts) recovery session alive and state fresh - skip"; exit 0
  fi
  echo "$(ts) recovery session stuck (no state progress >90min) - killing it for respawn"
  tmux kill-session -t claude-longrun 2>/dev/null
  rm -f "$MARK"
  sleep 3
fi

# Pick ONE candidate: armed + running + recorded reset time passed; oldest-stalled first
best=""
best_mt=9999999999
for f in "$D"/*.json; do
  [ -e "$f" ] || continue
  jq -e . "$f" >/dev/null 2>&1 || continue
  [ "$(jq -r '.status' "$f")" = "running" ] || continue
  [ "$(jq -r '.autoResume // false' "$f")" = "true" ] || continue
  nre=$(jq -r '.nextResetEpoch // empty' "$f")
  if [ -n "$nre" ] && [ "$now" -lt "$nre" ]; then continue; fi
  mt=$(mtime "$f")
  if [ "$mt" -lt "$best_mt" ]; then best="$f"; best_mt="$mt"; fi
done
[ -n "$best" ] || exit 0

# Any other live claude session owns recovery itself (never interfere with user sessions)
if pgrep -fl "claude" | grep -vE "long-run|tmux|grep|Claude.app" | grep -q "claude"; then
  echo "$(ts) live claude process found - skip"; exit 0
fi
if ! mkdir "$LOCK" 2>/dev/null; then echo "$(ts) lock held - skip"; exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
id=$(basename "$best" .json)
printf '%s\n' "$id" > "$MARK"
echo "$(ts) reviving '$id' (oldest halted armed pipeline) in tmux"
tmux new-session -d -s claude-longrun "bash $HOME/.claude/hooks/long-run-recovery-launch.sh '$best'"
echo "$(ts) spawned tmux session 'claude-longrun' (attach: tmux attach -t claude-longrun)"
