#!/bin/bash
# SessionStart hook. Surfaces every unfinished long-run pipeline to the new session.
# ARMED entries (autoResume:true)  -> instruct autonomous resume, one at a time.
# UNARMED entries                  -> inform the user only; never auto-resume.
D="$HOME/.claude/long-run-state"
LEGACY="$HOME/.claude/long-run-state.json"
if [ -f "$LEGACY" ]; then
  mkdir -p "$D"
  slug=$(basename "$(jq -r '.project // "pipeline"' "$LEGACY" 2>/dev/null)" 2>/dev/null) || slug=pipeline
  mv "$LEGACY" "$D/${slug}.json"
fi
ls "$D"/*.json >/dev/null 2>&1 || exit 0
open=$(for f in "$D"/*.json; do
  jq -e . "$f" >/dev/null 2>&1 || continue
  jq -e 'select(.status != "done")' "$f" >/dev/null 2>&1 && printf '%s\n' "$f"
done)
[ -n "$open" ] || exit 0
payload=$(printf '%s\n' "$open" | while IFS= read -r f; do
  jq -c '{id: (input_filename | split("/")[-1] | rtrimstr(".json")), status, autoResume: (.autoResume // false), project, runId, scriptPath, currentPhase}' "$f"
done | jq -s .)
g="Handle them per the Long-run recovery protocol in ~/.claude/CLAUDE.md: for each ARMED entry (autoResume:true) whose workflow is not currently running, resume it autonomously - but strictly ONE at a time (recoveries are serialized; parallel revivals race the shared usage quota). resumeFromRunId only works in the session that owns the journal; otherwise filter already-completed units (Done/ folder + git log) out of the workflow script and relaunch fresh, then recreate the in-session heartbeat cron. For UNARMED entries: do NOT auto-resume anything - briefly inform the user they exist and await instruction (user controls: longrun arm <id> | disarm <id> | done <id> | reopen <id>). If an entry is stale (actually finished), set its status to done instead."
upd=""
[ -s "$HOME/.claude/.longrun-kit-update-check" ] && upd=" [kit-update notice for the user: $(cat "$HOME/.claude/.longrun-kit-update-check")]"
jq -n --argjson s "$payload" --arg g "$g" --arg u "$upd" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:("[long-run-recovery] Unfinished long-run pipeline(s) recorded in ~/.claude/long-run-state/: " + ($s|tojson) + " -- " + $g + $u)}}'
