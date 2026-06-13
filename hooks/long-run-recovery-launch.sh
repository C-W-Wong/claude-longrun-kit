#!/bin/bash
# Runs inside tmux: starts an interactive claude session that resumes ONE armed pipeline.
# $1 = path to that pipeline's state file (defaults to the most recent entry).
# Interactive (not -p) so background workflows + in-session crons stay alive after the first turn.
# Override permission flags with CLAUDE_LONGRUN_PERM_FLAGS (default skips prompts entirely,
# required for truly unattended resume - only arm pipelines you trust).
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
PERM_FLAGS="${CLAUDE_LONGRUN_PERM_FLAGS:---dangerously-skip-permissions}"
D="$HOME/.claude/long-run-state"
SF="${1:-}"
if [ -z "$SF" ] || [ ! -f "$SF" ]; then SF=$(ls -t "$D"/*.json 2>/dev/null | head -1); fi
[ -n "$SF" ] || exit 0
proj=$(jq -r '.project' "$SF" 2>/dev/null)
cd "$proj" 2>/dev/null || cd "$HOME"
PROMPT="[long-run-recovery heartbeat] This session was auto-spawned by the OS heartbeat: the ARMED long-run pipeline recorded at $SF is halted and no session was alive. Read that state file and the project memory it points to, then follow the \"Long-run recovery\" protocol in ~/.claude/CLAUDE.md. Key points: resume ONLY this one pipeline (recoveries are serialized - the shared usage quota cannot support parallel revivals); apply the keep-vs-restore working-tree rule; this is a NEW session so the old workflow journal is unavailable - determine completed units from Done/ folders and git log, remove them from the workflow script, and launch it as a fresh run; recreate the in-session heartbeat cron; keep updating that state file (currentPhase/updatedAt) as you go. If the pipeline is actually complete, set its status to \"done\" and stop. Work autonomously - no user is watching."
claude --continue $PERM_FLAGS "$PROMPT"
rc=$?
if [ $rc -ne 0 ]; then
  echo "claude --continue exited $rc - starting fresh session"
  claude $PERM_FLAGS "$PROMPT"
fi
