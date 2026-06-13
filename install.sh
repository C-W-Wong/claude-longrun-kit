#!/bin/bash
# Claude Code long-run recovery kit - idempotent installer (macOS launchd / Linux systemd).
# Re-run safely anytime; existing settings are merged, never replaced.
set -euo pipefail

# Bootstrap: support `curl -fsSL .../install.sh | bash` - if the kit files are not
# sitting next to this script, download the repo tarball to a temp dir and install from there.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
if [ ! -f "$SRC_DIR/hooks/longrun" ]; then
  echo "Kit files not found locally - downloading https://github.com/C-W-Wong/claude-longrun-kit ..."
  TMP="$(mktemp -d)"
  curl -fsSL https://github.com/C-W-Wong/claude-longrun-kit/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP"
  SRC_DIR="$TMP/claude-longrun-kit-main"
fi
cd "$SRC_DIR"
echo "== claude-longrun-kit install =="

for dep in jq tmux claude; do
  command -v "$dep" >/dev/null 2>&1 || echo "WARN: '$dep' not found in PATH - install it before relying on recovery"
done

mkdir -p "$HOME/.claude/hooks" "$HOME/.local/bin"
cp hooks/long-run-launch-reminder.sh hooks/long-run-session-start.sh hooks/long-run-os-heartbeat.sh hooks/long-run-recovery-launch.sh hooks/longrun "$HOME/.claude/hooks/"
chmod +x "$HOME/.claude/hooks/long-run-launch-reminder.sh" "$HOME/.claude/hooks/long-run-session-start.sh" "$HOME/.claude/hooks/long-run-os-heartbeat.sh" "$HOME/.claude/hooks/long-run-recovery-launch.sh" "$HOME/.claude/hooks/longrun"
ln -sf "$HOME/.claude/hooks/longrun" "$HOME/.local/bin/longrun"
echo "hooks + longrun CLI installed"

S="$HOME/.claude/settings.json"
[ -f "$S" ] || echo '{}' > "$S"
jq '
  .hooks //= {} |
  .hooks.PostToolUse //= [] |
  (if ([ .hooks.PostToolUse[]? | select((.matcher // "") == "Workflow" and ((.hooks // []) | map(.command // "") | any(contains("long-run-launch-reminder")))) ] | length) == 0
   then .hooks.PostToolUse += [{"matcher":"Workflow","hooks":[{"type":"command","command":"bash ~/.claude/hooks/long-run-launch-reminder.sh","timeout":10,"statusMessage":"long-run recovery reminder"}]}]
   else . end) |
  .hooks.SessionStart //= [] |
  (if ([ .hooks.SessionStart[]? | select(((.hooks // []) | map(.command // "") | any(contains("long-run-session-start")))) ] | length) == 0
   then .hooks.SessionStart += [{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/long-run-session-start.sh","timeout":10,"statusMessage":"checking for unfinished long-run pipelines"}]}]
   else . end)
' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
jq -e .hooks "$S" >/dev/null
echo "settings.json hooks merged"

C="$HOME/.claude/CLAUDE.md"
touch "$C"
if ! grep -q "## Long-run recovery" "$C"; then
  printf '\n' >> "$C"
  cat claude-md-longrun-section.md >> "$C"
  echo "CLAUDE.md section appended"
else
  echo "CLAUDE.md section already present"
fi

if [ "$(uname -s)" = "Darwin" ]; then
  P="$HOME/Library/LaunchAgents/com.claude.longrun-heartbeat.plist"
  sed "s|__HOME__|$HOME|g" launchd.plist.template > "$P"
  launchctl unload "$P" 2>/dev/null || true
  launchctl load "$P"
  echo "launchd job loaded: com.claude.longrun-heartbeat (every 30 min)"
else
  mkdir -p "$HOME/.config/systemd/user"
  sed "s|__HOME__|$HOME|g" systemd/claude-longrun-heartbeat.service > "$HOME/.config/systemd/user/claude-longrun-heartbeat.service"
  cp systemd/claude-longrun-heartbeat.timer "$HOME/.config/systemd/user/claude-longrun-heartbeat.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now claude-longrun-heartbeat.timer
  echo "systemd user timer enabled: claude-longrun-heartbeat.timer"
fi

echo
echo "Done. Controls: longrun status | arm | disarm | done | log"
echo "Timing is universal: the heartbeat fires every 30 min and waits for the exact reset time recorded in the state file (nextResetEpoch) - no per-machine schedule config."
