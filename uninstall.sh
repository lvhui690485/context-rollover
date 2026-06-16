#!/usr/bin/env bash
#
# uninstall.sh — remove the claude-context-rollover hook from Claude Code.
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
arr = data.get("hooks", {}).get("PostToolUse", [])
def is_ours(entry):
    return any("hud-context-rollover.sh" in (h.get("command") or "")
               for h in entry.get("hooks", []))
kept = [e for e in arr if not is_ours(e)]
if "PostToolUse" in data.get("hooks", {}):
    if kept:
        data["hooks"]["PostToolUse"] = kept
    else:
        del data["hooks"]["PostToolUse"]
with open(settings, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("→ removed PostToolUse registration from settings.json")
PY
fi

rm -f "$DEST" 2>/dev/null && echo "→ removed $DEST" || true
echo "✅ uninstalled. State/logs left under $CONFIG_DIR/state/hud-rollover/ (delete manually if you want)."
