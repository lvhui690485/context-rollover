#!/usr/bin/env bash
# uninstall-codex.sh — remove the Codex rollover watcher + launchd agent.
set -euo pipefail
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
LABEL="com.claude-context-rollover.codex-watcher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

[ -f "$PLIST" ] && { launchctl unload "$PLIST" 2>/dev/null || true; rm -f "$PLIST"; echo "→ removed launchd agent"; }
# stop any stray foreground watcher
pkill -f "codex-context-watcher.sh" 2>/dev/null || true
rm -rf "$CODEX_HOME/rollover" 2>/dev/null || true
echo "✅ uninstalled. State/logs left under $CODEX_HOME/rollover-state/ (delete manually if you want)."
