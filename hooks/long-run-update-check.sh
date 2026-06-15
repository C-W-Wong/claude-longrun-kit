#!/bin/bash
# Notify-only update check. Compares the installed kit commit against origin/main
# via the GitHub API. Result is cached for 24h; offline/rate-limit = silent.
# This script NEVER downloads or executes an update - it only prints one line.
PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
VF="$HOME/.claude/.longrun-kit-version"
CF="$HOME/.claude/.longrun-kit-update-check"
[ -s "$VF" ] || exit 0
local_sha=$(cat "$VF")
now=$(date +%s)
if [ -f "$CF" ]; then
  mt=$(stat -c %Y "$CF" 2>/dev/null || stat -f %m "$CF" 2>/dev/null || echo 0)
  if [ $(( now - mt )) -lt 86400 ]; then cat "$CF"; exit 0; fi
fi
remote_sha=$(curl -fsSL --max-time 3 https://api.github.com/repos/C-W-Wong/claude-longrun-kit/commits/main 2>/dev/null | jq -r '.sha // empty' 2>/dev/null)
if [ -z "$remote_sha" ]; then : > "$CF"; exit 0; fi
if [ "${remote_sha:0:12}" != "${local_sha:0:12}" ]; then
  printf 'claude-longrun-kit update available (%.7s -> %.7s). Upgrade is never automatic - run: curl -fsSL https://raw.githubusercontent.com/C-W-Wong/claude-longrun-kit/main/install.sh | bash\n' "$local_sha" "$remote_sha" > "$CF"
else
  : > "$CF"
fi
cat "$CF"
