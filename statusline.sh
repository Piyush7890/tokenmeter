#!/bin/sh
# TokenMeter hook for Claude Code's status line. Claude Code pipes a JSON payload (including
# `rate_limits`) to this script after every reply; save it atomically for the menu bar app.
dir="$HOME/.claude/tokenmeter"
tmp="$dir/.status.$$"
trap 'rm -f "$tmp"' EXIT
mkdir -p "$dir"
cat > "$tmp" || exit 0
# If you already had a status line, hand it the same payload so it keeps working.
[ -s "$dir/next-command" ] && /bin/bash -c "$(cat "$dir/next-command")" < "$tmp"
mv -f "$tmp" "$dir/status.json"
