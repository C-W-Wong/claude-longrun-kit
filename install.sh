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
cp hooks/long-run-launch-reminder.sh hooks/long-run-session-start.sh hooks/long-run-os-heartbeat.sh hooks/long-run-recovery-launch.sh hooks/long-run-update-check.sh hooks/longrun "$HOME/.claude/hooks/"
chmod +x "$HOME/.claude/hooks/long-run-launch-reminder.sh" "$HOME/.claude/hooks/long-run-session-start.sh" "$HOME/.claude/hooks/long-run-os-heartbeat.sh" "$HOME/.claude/hooks/long-run-recovery-launch.sh" "$HOME/.claude/hooks/long-run-update-check.sh" "$HOME/.claude/hooks/longrun"
ln -sf "$HOME/.claude/hooks/longrun" "$HOME/.local/bin/longrun"
echo "hooks + longrun CLI installed"

# Stamp the installed version for the notify-only update check
KIT_SHA=""
if command -v git >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
  KIT_SHA=$(git rev-parse HEAD)
else
  KIT_SHA=$(curl -fsSL --max-time 5 https://api.github.com/repos/C-W-Wong/claude-longrun-kit/commits/main 2>/dev/null | jq -r '.sha // empty' 2>/dev/null || true)
fi
if [ -n "$KIT_SHA" ]; then
  echo "$KIT_SHA" > "$HOME/.claude/.longrun-kit-version"
  rm -f "$HOME/.claude/.longrun-kit-update-check"
  echo "installed version stamped: ${KIT_SHA:0:7}"
fi

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
B="<!-- claude-longrun-kit:begin -->"
E="<!-- claude-longrun-kit:end -->"
if grep -qF "$B" "$C"; then
  # managed section exists: replace it in place so protocol text upgrades with the kit
  awk -v b="$B" -v e="$E" 'index($0,b){skip=1; next} index($0,e){skip=0; next} !skip{print}' "$C" > "$C.tmp" && mv "$C.tmp" "$C"
  cat claude-md-longrun-section.md >> "$C"
  echo "CLAUDE.md section updated to this kit version"
elif grep -q "## Long-run recovery" "$C"; then
  echo "WARN: CLAUDE.md contains an unmanaged 'Long-run recovery' section (pre-marker install)."
  echo "      Delete it and re-run ./install.sh to switch to the auto-updating managed section."
else
  printf '\n' >> "$C"
  cat claude-md-longrun-section.md >> "$C"
  echo "CLAUDE.md section appended"
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
