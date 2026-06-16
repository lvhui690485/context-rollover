#!/usr/bin/env bash
#
# install.sh — install the claude-context-rollover hook into Claude Code.
#
# - copies hooks/hud-context-rollover.sh to $CLAUDE_CONFIG_DIR/hooks/
# - registers it as a PostToolUse hook in settings.json (idempotent, backed up)
#
# Re-running is safe. Uninstall with ./uninstall.sh.
#
set -euo pipefail

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/hooks/hud-context-rollover.sh"
DEST_DIR="$CONFIG_DIR/hooks"
DEST="$DEST_DIR/hud-context-rollover.sh"
SETTINGS="$CONFIG_DIR/settings.json"

COOLDOWN="${HUD_ROLLOVER_COOLDOWN:-300}"   # conservative default for first run

command -v python3 >/dev/null 2>&1 || { echo "error: python3 required"; exit 1; }
[ -f "$SRC" ] || { echo "error: $SRC not found"; exit 1; }

echo "→ installing hook script to $DEST"
mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"

if [ ! -f "$SETTINGS" ]; then
  echo "→ creating $SETTINGS"
  printf '{\n  "hooks": {}\n}\n' > "$SETTINGS"
fi

ts="$(python3 -c 'import time;print(time.strftime("%Y%m%d%H%M%S"))')"
cp "$SETTINGS" "$SETTINGS.bak-rollover-$ts"
echo "→ backed up settings.json to $SETTINGS.bak-rollover-$ts"

CMD="HUD_ROLLOVER_COOLDOWN=$COOLDOWN $DEST"

CMD="$CMD" SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os, sys
settings = os.environ["SETTINGS"]
cmd = os.environ["CMD"]
with open(settings) as f:
    data = json.load(f)
hooks = data.setdefault("hooks", {})
arr = hooks.setdefault("PostToolUse", [])

# remove any prior rollover registration so re-install is idempotent
def is_ours(entry):
    return any("hud-context-rollover.sh" in (h.get("command") or "")
               for h in entry.get("hooks", []))
arr[:] = [e for e in arr if not is_ours(e)]

arr.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})
with open(settings, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("→ registered PostToolUse hook:", cmd)
PY

# remove any stale kill switch so the hook is actually armed
rm -f "$CONFIG_DIR/state/hud-rollover/DISABLED" 2>/dev/null || true

echo
echo "✅ installed. Takes effect in NEW Claude Code sessions."
echo "   Requires the claude-hud plugin (provides the context% signal)."
echo "   Threshold 60% (default). Disable anytime:  touch $CONFIG_DIR/state/hud-rollover/DISABLED"
