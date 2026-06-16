#!/usr/bin/env bash
#
# uninstall.sh — remove the context-rollover hook from Claude Code.
#
set -euo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONFIG_DIR/settings.json"
DEST="$CONFIG_DIR/hooks/hud-context-rollover.sh"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 required"; exit 1; }

if [ -f "$SETTINGS" ]; then
  ts="$(python3 -c 'import time;print(time.strftime("%Y%m%d%H%M%S"))')"
  cp "$SETTINGS" "$SETTINGS.bak-rollover-$ts"
  SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
settings = os.environ["SETTINGS"]
with open(settings) as f:
    data = json.load(f)
hooks = data.get("hooks", {})

def strip(event, needle):
    arr = hooks.get(event)
    if not arr:
        return
    kept = [e for e in arr
            if not any(needle in (h.get("command") or "") for h in e.get("hooks", []))]
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]

strip("PostToolUse", "hud-context-rollover.sh")
strip("SessionStart", "session-start-handoff.sh")
with open(settings, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("→ removed PostToolUse + SessionStart registrations from settings.json")
PY
fi

rm -f "$DEST" 2>/dev/null && echo "→ removed $DEST" || true
rm -f "$CONFIG_DIR/hooks/session-start-handoff.sh" 2>/dev/null || true
rm -f "$CONFIG_DIR/hooks/lib/rollover-handoff.py" "$CONFIG_DIR/hooks/lib/rollover-core.sh" 2>/dev/null || true
rmdir "$CONFIG_DIR/hooks/lib" 2>/dev/null || true
echo "✅ uninstalled. State/logs left under $CONFIG_DIR/state/hud-rollover/ (delete manually if you want)."
