#!/bin/bash
# TokenMeter installer. Usage:
#   ./install.sh             build, install to ~/Applications, connect to Claude Code, launch
#   ./install.sh uninstall   quit and remove the app, restore your previous status line
set -euo pipefail
cd "$(dirname "$0")"

DATA="$HOME/.claude/tokenmeter"
HOOK="$DATA/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"
APP="$HOME/Applications/TokenMeter.app"

# Muted colors in a terminal, plain text when piped.
if [[ -t 1 ]]; then
  bold=$'\e[1m' dim=$'\e[2m' ok=$'\e[32m' note=$'\e[33m' bad=$'\e[31m' off=$'\e[0m'
else
  bold='' dim='' ok='' note='' bad='' off=''
fi
step() { echo "  ${ok}✓${off} $*"; }
warn() { echo "  ${note}!${off} $*"; }
fail() { echo "  ${bad}✗${off} $*" >&2; echo >&2; exit 1; }

# Points Claude Code's status line at the hook ("connect"), or puts back what was there ("disconnect").
# An existing status line is kept: the hook passes Claude Code's payload on to it.
statusline() {
  mkdir -p "$DATA"
  osascript -l JavaScript - "$1" "$SETTINGS" "$HOOK" "$DATA" <<'JS'
ObjC.import('Foundation');
ObjC.import('stdlib');
function read(path) {
  const s = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return s.isNil() ? null : s.js;
}
function write(path, text) { $(text).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null); }
function run([mode, settingsPath, hook, data]) {
  const raw = read(settingsPath);
  let settings = {};
  try { if (raw && raw.trim()) settings = JSON.parse(raw); }
  catch (e) {
    console.log('  ✗ ' + settingsPath + " isn't valid JSON, so I left it alone. Fix it and run me again.");
    $.exit(1);
  }
  const cur = settings.statusLine;
  const ours = !!(cur && cur.command && cur.command.endsWith('/.claude/tokenmeter/statusline.sh'));
  if (mode === 'connect') {
    if (ours) return 'Already plugged into Claude Code';
    if (raw !== null) write(data + '/settings.backup.json', raw);
    if (cur) {
      write(data + '/previous-statusline.json', JSON.stringify(cur));
      if (cur.command) write(data + '/next-command', cur.command);
    }
    settings.statusLine = { type: 'command', command: hook };
    write(settingsPath, JSON.stringify(settings, null, 2) + '\n');
    return cur ? 'Plugged into Claude Code (your own status line keeps running too)' : 'Plugged into Claude Code';
  }
  if (!ours) return 'Claude Code settings were already clean';
  const prev = read(data + '/previous-statusline.json');
  if (prev) settings.statusLine = JSON.parse(prev); else delete settings.statusLine;
  write(settingsPath, JSON.stringify(settings, null, 2) + '\n');
  return prev ? 'Your original status line is back' : 'Claude Code settings restored';
}
JS
}

echo
echo "  ${bold}◑ TokenMeter${off}"
echo "  ${dim}a quiet gauge for your Claude limits${off}"
echo

if [[ "${1:-}" == "uninstall" ]]; then
  pkill -x TokenMeter 2>/dev/null || true
  msg=$(statusline disconnect)
  step "$msg"
  rm -rf "$APP" "$DATA"
  defaults delete local.tokenmeter 2>/dev/null || true
  step "App and its data removed"
  echo
  echo "  ${dim}All packed up. Thanks for giving it a spin.${off}"
  echo
  exit 0
fi

if ! command -v claude >/dev/null 2>&1 && [[ ! -d "$HOME/.claude" ]]; then
  fail "Claude Code isn't here yet. Grab it at https://claude.com/claude-code, log in, and run me again."
fi
# Only checks that the Keychain entry exists; the token itself is never read here.
if security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  step "Found Claude Code, signed in and ready"
else
  warn "Claude Code isn't signed in yet. Run ${bold}claude${off} and log in with Pro or Max;"
  echo "    TokenMeter will notice on its own, no reinstall needed."
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  fail "TokenMeter builds from source and needs Apple's Command Line Tools.
    Run ${bold}xcode-select --install${off}, then run me again."
fi

BUILD="build/TokenMeter.app"
rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" Sources/*.swift -o "$BUILD/Contents/MacOS/TokenMeter"
cat > "$BUILD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TokenMeter</string>
  <key>CFBundleIdentifier</key><string>local.tokenmeter</string>
  <key>CFBundleExecutable</key><string>TokenMeter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$BUILD" 2>/dev/null
step "Built fresh from source"

pkill -x TokenMeter 2>/dev/null && sleep 1 || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R "$BUILD" "$APP"
step "Moved into ~/Applications"

mkdir -p "$DATA"
cp statusline.sh "$HOOK"
chmod +x "$HOOK"
msg=$(statusline connect)
step "$msg"
[[ -f "$DATA/settings.backup.json" ]] && echo "    ${dim}settings backup: ~/.claude/tokenmeter/settings.backup.json${off}"

open "$APP"
echo
echo "  All set. Look up at your menu bar ↗"
echo "  ${dim}The rings fill in after your next Claude reply. Click them for the details.${off}"
echo
