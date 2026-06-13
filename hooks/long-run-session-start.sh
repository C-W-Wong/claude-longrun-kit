#!/bin/bash
# SessionStart hook. Surfaces an unfinished long-run pipeline to the new session.
# ARMED (autoResume:true)  -> instruct autonomous resume.
# UNARMED (autoResume:false)-> inform the user only; never auto-resume.
f="$HOME/.claude/long-run-state.json"
[ -f "$f" ] || exit 0
jq -e . "$f" >/dev/null 2>&1 || exit 0
jq -e 'select(.status == "done")' "$f" >/dev/null 2>&1 && exit 0
armed=$(jq -r '.autoResume // false' "$f")
if [ "$armed" = "true" ]; then
  g="This pipeline is ARMED (autoResume:true): if its workflow is not currently running, resume it autonomously NOW per the protocol - keep-vs-restore working-tree rule; resumeFromRunId only works in the session that owns the journal, otherwise filter already-completed units (Done/ folder + git log) out of the workflow script and relaunch fresh; recreate the in-session heartbeat cron."
else
  g="This pipeline is NOT armed (autoResume:false): do NOT auto-resume anything. Briefly inform the user that this halted pipeline exists and await their instruction (user controls: longrun arm | disarm | done)."
fi
jq -n --slurpfile s "$f" --arg g "$g" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("[long-run-recovery] Unfinished long-run pipeline recorded in ~/.claude/long-run-state.json: " + ($s[0]|tojson) + " -- " + $g + " Full protocol: ~/.claude/CLAUDE.md section \"Long-run recovery\". Cross-check project memory before acting; if the state file is stale (pipeline actually finished), set status:done instead.")}}'
