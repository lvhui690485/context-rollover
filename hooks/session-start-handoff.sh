#!/usr/bin/env bash
#
# session-start-handoff.sh — a Claude Code SessionStart hook.
#
# Companion to hud-context-rollover.sh. When a fresh session starts in a repo
# that has a *recent* rollover handoff (.claude/rollover-handoff.md), this injects
# the handoff content straight into the new session's context, so continuation
# does not depend on the seed prompt being followed.
#
# Injects at most once per generated handoff (tracked by mtime in the hook's
# state dir) and only if the handoff is fresh (default 15 min), so old handoffs
# never leak into unrelated future sessions.
#
# Env:
#   HUD_ROLLOVER_INJECT_MAXAGE  seconds; skip handoffs older than this (default 900)
#   HUD_ROLLOVER_HANDOFF_PATH   repo-relative handoff path (must match the rollover hook)
#   HUD_ROLLOVER_DISABLE=1      off
#
set -u

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_DIR="$CONFIG_DIR/state/hud-rollover"
[ -e "$STATE_DIR/DISABLED" ] && exit 0
[ -n "${HUD_ROLLOVER_DISABLE:-}" ] && exit 0

PY="$(command -v python3 || echo /usr/bin/python3)"
json="$(cat 2>/dev/null)"
[ -n "$json" ] || exit 0

cwd="$(printf '%s' "$json" | "$PY" -c 'import sys,json
try: print((json.load(sys.stdin).get("cwd") or "").strip())
except Exception: print("")' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

rel="${HUD_ROLLOVER_HANDOFF_PATH:-.claude/rollover-handoff.md}"
hf="$cwd/$rel"
[ -f "$hf" ] || exit 0

# freshness gate. A rollover spawns the new window within ~1s, so a tight window
# is plenty and shrinks the chance of injecting a stale handoff into an unrelated
# session opened manually in the same repo soon after.
mtime="$(stat -f %m "$hf" 2>/dev/null || stat -c %Y "$hf" 2>/dev/null)"
case "$mtime" in ''|*[!0-9]*) exit 0;; esac
now="$(date +%s 2>/dev/null)"
maxage="${HUD_ROLLOVER_INJECT_MAXAGE:-300}"
[ $(( now - mtime )) -le "$maxage" ] || exit 0

# consume-once: skip if we already injected this exact handoff (by mtime)
mkdir -p "$STATE_DIR" 2>/dev/null
key="$(printf '%s' "$cwd" | shasum -a 256 2>/dev/null | awk '{print $1}')"
marker="$STATE_DIR/injected-$key"
[ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$mtime" ] && exit 0
printf '%s' "$mtime" > "$marker" 2>/dev/null

# inject the handoff as SessionStart additionalContext
"$PY" - "$hf" <<'PY'
import json, sys
try:
    body = open(sys.argv[1], encoding="utf-8", errors="replace").read()
except Exception:
    sys.exit(0)
ctx = ("A previous Claude Code session in this repo rolled over because it hit "
       "its context limit. This is its handoff — continue the in-progress work "
       "from here; do not redo completed work:\n\n" + body)
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ctx,
}}))
PY
exit 0
