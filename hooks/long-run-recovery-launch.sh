#!/bin/bash
# Runs inside tmux: starts an interactive claude session that resumes the armed pipeline.
# Interactive (not -p) so background workflows + in-session crons stay alive after the first turn.
# Override permission flags with CLAUDE_LONGRUN_PERM_FLAGS (default skips prompts entirely,
# required for truly unattended resume - only arm pipelines you trust).
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
PERM_FLAGS="${CLAUDE_LONGRUN_PERM_FLAGS:---dangerously-skip-permissions}"
F="$HOME/.claude/long-run-state.json"
proj=$(jq -r '.project' "$F" 2>/dev/null)
cd "$proj" 2>/dev/null || cd "$HOME"
PROMPT='[long-run-recovery heartbeat] This session was auto-spawned by the OS heartbeat: an ARMED long-run pipeline (autoResume:true in ~/.claude/long-run-state.json) is halted and no session was alive. Read that state file and the project memory it points to, then follow the "Long-run recovery" protocol in ~/.claude/CLAUDE.md. Key points: apply the keep-vs-restore working-tree rule; this is a NEW session so the old workflow journal is unavailable - determine completed units from Done/ folders and git log, remove them from the workflow script, and launch it as a fresh run; recreate the in-session heartbeat cron; update the state file (currentPhase/updatedAt). If the pipeline is actually complete, set status:"done" and stop. Work autonomously - no user is watching.'
claude --continue $PERM_FLAGS "$PROMPT"
rc=$?
if [ $rc -ne 0 ]; then
  echo "claude --continue exited $rc - starting fresh session"
  claude $PERM_FLAGS "$PROMPT"
fi
