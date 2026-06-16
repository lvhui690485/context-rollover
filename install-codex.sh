#!/usr/bin/env bash
#
# install-codex.sh — install the Codex rollover watcher (zero-intrusion).
#
# Copies the watcher + handoff helper into ~/.codex/rollover/ and, by default,
# installs a launchd agent so the watcher runs in the background and restarts on
# login. It does NOT touch ~/.codex/config.toml or your notify program.
#
#   ./install-codex.sh                 # install + launchd agent
#   ./install-codex.sh --no-daemon     # install files only; run it yourself
#
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$CODEX_HOME/rollover"
LABEL="com.context-rollover.codex-watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DAEMON=1
[ "${1:-}" = "--no-daemon" ] && DAEMON=0

command -v python3 >/dev/null 2>&1 || { echo "error: python3 required"; exit 1; }
command -v codex   >/dev/null 2>&1 || echo "warning: 'codex' not on PATH — the watcher will still install"

echo "→ installing watcher + handoff helper to $DEST"
mkdir -p "$DEST"
cp "$HERE/codex/codex-context-watcher.sh" "$DEST/codex-context-watcher.sh"
cp "$HERE/hooks/lib/rollover-handoff.py"  "$DEST/rollover-handoff.py"
cp "$HERE/hooks/lib/rollover-core.sh"     "$DEST/rollover-core.sh"
chmod +x "$DEST/codex-context-watcher.sh"
rm -f "$DEST/../rollover-state/DISABLED" 2>/dev/null || true

if [ "$DAEMON" -eq 0 ]; then
  echo
  echo "✅ installed (files only). Start the watcher yourself:"
  echo "   nohup $DEST/codex-context-watcher.sh >/dev/null 2>&1 &"
  exit 0
fi

echo "→ installing launchd agent: $PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$DEST/codex-context-watcher.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$CODEX_HOME/rollover-state/launchd.err</string>
  <key>StandardOutPath</key><string>$CODEX_HOME/rollover-state/launchd.out</string>
</dict>
</plist>
PLISTEOF

mkdir -p "$CODEX_HOME/rollover-state"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST" 2>/dev/null || true

echo
echo "✅ installed. The watcher is running in the background (launchd: $LABEL),"
echo "   threshold 60%, and restarts on login. It never touches config.toml/notify."
echo "   Stop it:   launchctl unload $PLIST"
echo "   Disable:   touch $CODEX_HOME/rollover-state/DISABLED"
echo "   Logs:      cat $CODEX_HOME/rollover-state/rollover.log"
