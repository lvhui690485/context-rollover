#!/usr/bin/env bash
#
# install.sh — install the context-rollover hook into Claude Code.
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
SRC_SS="$HERE/hooks/session-start-handoff.sh"
DEST_DIR="$CONFIG_DIR/hooks"
DEST="$DEST_DIR/hud-context-rollover.sh"
DEST_SS="$DEST_DIR/session-start-handoff.sh"
SETTINGS="$CONFIG_DIR/settings.json"

COOLDOWN="${HUD_ROLLOVER_COOLDOWN:-300}"   # conservative default for first run

command -v python3 >/dev/null 2>&1 || { echo "error: python3 required"; exit 1; }
[ -f "$SRC" ] || { echo "error: $SRC not found"; exit 1; }

echo "→ installing hook script to $DEST"
mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"

# SessionStart companion: injects the handoff into the new session's context
if [ -f "$SRC_SS" ]; then
  echo "→ installing SessionStart hook to $DEST_SS"
  cp "$SRC_SS" "$DEST_SS"
  chmod +x "$DEST_SS"
fi

# shared lib: handoff generator (.py) + core helpers (.sh) the hook sources
if [ -d "$HERE/hooks/lib" ]; then
  echo "→ installing lib helpers to $DEST_DIR/lib/"
  mkdir -p "$DEST_DIR/lib"
  cp "$HERE/hooks/lib/"*.py "$HERE/hooks/lib/"*.sh "$DEST_DIR/lib/" 2>/dev/null || true
fi

if [ ! -f "$SETTINGS" ]; then
  echo "→ creating $SETTINGS"
  printf '{\n  "hooks": {}\n}\n' > "$SETTINGS"
fi

ts="$(python3 -c 'import time;print(time.strftime("%Y%m%d%H%M%S"))')"
cp "$SETTINGS" "$SETTINGS.bak-rollover-$ts"
echo "→ backed up settings.json to $SETTINGS.bak-rollover-$ts"

CMD="HUD_ROLLOVER_COOLDOWN=$COOLDOWN $DEST"

CMD="$CMD" CMD_SS="$DEST_SS" SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os
settings = os.environ["SETTINGS"]
cmd = os.environ["CMD"]
cmd_ss = os.environ["CMD_SS"]
with open(settings) as f:
    data = json.load(f)
hooks = data.setdefault("hooks", {})

def register(event, command, needle):
    arr = hooks.setdefault(event, [])
    # remove any prior registration of ours so re-install is idempotent
    arr[:] = [e for e in arr
              if not any(needle in (h.get("command") or "") for h in e.get("hooks", []))]
    arr.append({"matcher": "", "hooks": [{"type": "command", "command": command}]})

register("PostToolUse", cmd, "hud-context-rollover.sh")
if os.path.exists(cmd_ss):
    register("SessionStart", cmd_ss, "session-start-handoff.sh")

with open(settings, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("→ registered PostToolUse:", cmd)
print("→ registered SessionStart:", cmd_ss)
PY

# remove any stale kill switch so the hook is actually armed
rm -f "$CONFIG_DIR/state/hud-rollover/DISABLED" 2>/dev/null || true

echo
echo "✅ installed. Takes effect in NEW Claude Code sessions."
echo "   Requires the claude-hud plugin (provides the context% signal)."
echo "   Threshold 60% (default). Disable anytime:  touch $CONFIG_DIR/state/hud-rollover/DISABLED"
