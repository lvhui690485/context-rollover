#!/usr/bin/env bash
#
# codex-context-watcher.sh — Codex CLI rollover trigger (zero-intrusion).
#
# Codex has no per-tool hook like Claude Code's PostToolUse, and its `notify`
# slot is often already used. So instead of touching your config, this is a tiny
# background poller: every few seconds it scans the active Codex session rollout
# files, computes context usage from the embedded token_count, and when a session
# crosses the threshold AND has gone idle (turn ended), it generates a handoff and
# opens a fresh `codex` window to continue. The old session is already idle
# (Codex emits token_count at turn-end), so there is nothing to forcibly stop.
#
# Run it once in the background:
#     nohup ./codex/codex-context-watcher.sh >/dev/null 2>&1 &
# or install a launchd agent (see install-codex.sh).
#
# Signal:  used% = last_token_usage.input_tokens / model_context_window
#          (both live inside the rollout's token_count event — no plugin needed)
#
# Safety nets mirror the Claude side: per-session fire-once latch, global
# cooldown, burst auto-disable, and a DISABLED file kill switch.
#
# Env:
#   CODEX_ROLLOVER_THRESHOLD   percent, default 60
#   CODEX_ROLLOVER_POLL        seconds between scans, default 8
#   CODEX_ROLLOVER_IDLE        seconds of file quiescence = turn ended, default 5
#   CODEX_ROLLOVER_ACTIVE      only consider sessions touched within N s, default 180
#   CODEX_ROLLOVER_COOLDOWN    seconds between spawns globally, default 180
#   CODEX_ROLLOVER_MAX_BURST   spawns-in-10min that auto-trips the kill switch, default 5
#   CODEX_ROLLOVER_SEED        override the seed prompt
#   CODEX_ROLLOVER_ONCE=1      run a single scan and exit (for testing)
#   CODEX_ROLLOVER_DRYRUN=1    decide + log, never spawn
#   CODEX_HOME                 default ~/.codex
#
set -u

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SESS_DIR="$CODEX_HOME/sessions"
STATE_DIR="${CODEX_ROLLOVER_STATE:-$CODEX_HOME/rollover-state}"
LOG="$STATE_DIR/rollover.log"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
HANDOFF_GEN="$SELF_DIR/../hooks/lib/rollover-handoff.py"
[ -f "$HANDOFF_GEN" ] || HANDOFF_GEN="$SELF_DIR/rollover-handoff.py"
PY="$(command -v python3 || echo /usr/bin/python3)"

THRESHOLD="${CODEX_ROLLOVER_THRESHOLD:-60}"
POLL="${CODEX_ROLLOVER_POLL:-8}"
IDLE="${CODEX_ROLLOVER_IDLE:-5}"
ACTIVE="${CODEX_ROLLOVER_ACTIVE:-180}"
COOLDOWN="${CODEX_ROLLOVER_COOLDOWN:-180}"
MAXBURST="${CODEX_ROLLOVER_MAX_BURST:-5}"

mkdir -p "$STATE_DIR" 2>/dev/null

log(){ printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }

# read a session file's: used% , cwd , session-id  (one line, tab-separated)
read_session() {
  "$PY" - "$1" <<'PY'
import json, os, sys
path = sys.argv[1]
cwd = sid = win = cur = None

# session_meta is at the top: scan the head and stop once found (don't parse the
# whole — possibly multi-MB — file on every poll).
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f):
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("type") == "session_meta":
                p = o.get("payload", {})
                cwd = p.get("cwd"); sid = p.get("id")
                break
            if i > 200:
                break
except Exception:
    sys.exit(0)

# the latest token_count is appended last: read only a tail chunk and scan
# backward for the most recent one.
try:
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        f.seek(max(0, size - 256 * 1024))
        tail = f.read().decode("utf-8", "replace").splitlines()
    for line in reversed(tail):
        try:
            o = json.loads(line)
        except Exception:
            continue
        p = o.get("payload", {})
        if isinstance(p, dict) and p.get("type") == "token_count" and p.get("info"):
            info = p["info"]
            win = info.get("model_context_window")
            cur = (info.get("last_token_usage") or {}).get("input_tokens")
            break
except Exception:
    pass

if not (cwd and win and cur):
    sys.exit(0)
pct = round(100 * cur / win)
print("%d\t%s\t%s" % (pct, cwd, sid or os.path.basename(path)))
PY
}

# spawn a fresh codex window (reuses tmux/iTerm/Ghostty/Terminal backends)
spawn_codex() {
  local cwd="$1" seed="$2" newcmd esc guard sani
  esc="$(printf '%s' "$seed" | sed "s/'/'\\\\''/g")"
  # `open` hands our env to the spawned app. If the inherited CODEX_HOME has no
  # auth.json (stale/test/temp), the child codex re-prompts login — drop it so it
  # falls back to the default ~/.codex creds. Evaluate in the CHILD shell.
  guard='[ -n "${CODEX_HOME:-}" ] && [ ! -f "${CODEX_HOME:-}/auth.json" ] && unset CODEX_HOME'
  # never let the watcher's tuning env leak into the spawned session
  sani='unset CODEX_ROLLOVER_THRESHOLD CODEX_ROLLOVER_POLL CODEX_ROLLOVER_IDLE CODEX_ROLLOVER_ACTIVE CODEX_ROLLOVER_COOLDOWN CODEX_ROLLOVER_MAX_BURST CODEX_ROLLOVER_SEED CODEX_ROLLOVER_ONCE CODEX_ROLLOVER_DRYRUN CODEX_ROLLOVER_STATE CODEX_ROLLOVER_HANDOFF_PATH'
  newcmd="$guard; $sani; cd $(printf '%q' "$cwd") && codex '$esc'"
  if [ -n "${TMUX:-}" ] && tmux split-window -h -c "$cwd" "$newcmd" 2>/dev/null; then return 0; fi
  if [ "${TERM_PROGRAM:-}" = "iTerm.app" ] && osascript \
      -e 'on run argv' -e 'tell application "iTerm"' -e 'activate' \
      -e 'tell current session of current window to set s to (split vertically with default profile)' \
      -e 'tell s to write text (item 1 of argv)' -e 'end tell' -e 'end run' "$newcmd" >/dev/null 2>&1; then return 0; fi
  if { [ "${TERM_PROGRAM:-}" = "ghostty" ] || [ -d /Applications/Ghostty.app ]; } && \
      open -na Ghostty.app --args -e zsh -lc "$newcmd" >/dev/null 2>&1; then return 0; fi
  osascript -e 'on run argv' -e 'tell application "Terminal"' -e 'activate' \
      -e 'do script (item 1 of argv)' -e 'end tell' -e 'end run' "$newcmd" >/dev/null 2>&1
}

handle_session() {
  local f="$1" now mtime age info pct cwd sid
  now="$(date +%s)"
  mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)"
  case "$mtime" in ''|*[!0-9]*) return 0;; esac
  age=$(( now - mtime ))
  # only recently-active sessions, and only once they've gone idle (turn ended)
  [ "$age" -le "$ACTIVE" ] || return 0
  [ "$age" -ge "$IDLE" ]   || return 0

  info="$(read_session "$f")" || return 0
  [ -n "$info" ] || return 0
  pct="${info%%	*}"; rest="${info#*	}"; cwd="${rest%%	*}"; sid="${rest##*	}"
  case "$pct" in ''|*[!0-9]*) return 0;; esac
  [ "$pct" -ge "$THRESHOLD" ] || return 0
  [ -d "$cwd" ] || return 0

  # fire-once per session id
  local latch="$STATE_DIR/fired-$sid"
  [ -e "$latch" ] && return 0

  if [ -n "${CODEX_ROLLOVER_DRYRUN:-}" ]; then
    log "DRYRUN would-roll pct=$pct sid=$sid cwd=$cwd"
    echo "[codex-rollover dry-run] pct=$pct% sid=$sid cwd=$cwd" >&2
    : > "$latch" 2>/dev/null
    return 0
  fi

  # global cooldown
  local cdfile="$STATE_DIR/last-spawn.epoch" last
  if [ -f "$cdfile" ]; then
    last="$(cat "$cdfile" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0;; esac
    if [ $(( now - last )) -lt "$COOLDOWN" ]; then log "COOLDOWN-skip pct=$pct sid=$sid"; return 0; fi
  fi
  # burst auto-disable
  local recent
  recent="$("$PY" -c '
import sys,time,datetime
log,now=sys.argv[1],int(sys.argv[2]); c=0
try:
    for ln in open(log):
        if " SPAWN " not in ln: continue
        try:
            ep=time.mktime(datetime.datetime.strptime(ln[:19],"%Y-%m-%d %H:%M:%S").timetuple())
            if ep>=now-600: c+=1
        except Exception: pass
except FileNotFoundError: pass
print(c)' "$LOG" "$now" 2>/dev/null)"
  case "$recent" in ''|*[!0-9]*) recent=0;; esac
  if [ "$recent" -ge "$MAXBURST" ]; then : > "$STATE_DIR/DISABLED"; log "AUTO-DISABLE burst=$recent"; return 0; fi

  : > "$latch" 2>/dev/null

  # generate handoff into the repo (same path scheme as the Claude side)
  local rel="${CODEX_ROLLOVER_HANDOFF_PATH:-.claude/rollover-handoff.md}"
  local hf="$cwd/$rel" seed
  mkdir -p "$(dirname "$hf")" 2>/dev/null
  if [ -f "$HANDOFF_GEN" ] && "$PY" "$HANDOFF_GEN" "$f" "$cwd" "$pct" "$hf" >/dev/null 2>&1 && [ -s "$hf" ]; then
    if [ -e "$cwd/.git" ]; then   # file in worktrees, dir in normal repos
      excl="$(git -C "$cwd" rev-parse --git-path info/exclude 2>/dev/null)"
      if [ -n "$excl" ]; then
        case "$excl" in /*) :;; *) excl="$cwd/$excl";; esac
        mkdir -p "$(dirname "$excl")" 2>/dev/null
        grep -qxF "$rel" "$excl" 2>/dev/null || printf '%s\n' "$rel" >> "$excl" 2>/dev/null || true
      fi
    fi
    seed="${CODEX_ROLLOVER_SEED:-The previous codex session reached ${pct}% context and handed off to this window. First read ./$rel (task, plan, recent actions, edited files, git diff), then continue the in-progress work from where it left off. Do not redo completed work.}"
  else
    seed="${CODEX_ROLLOVER_SEED:-The previous codex session reached ${pct}% context and handed off to this window. Reconstruct from git status/diff and continue from the next step. Do not redo completed work.}"
  fi

  if spawn_codex "$cwd" "$seed"; then
    date +%s > "$cdfile" 2>/dev/null
    log "SPAWN pct=$pct sid=$sid cwd=$cwd"
  else
    rm -f "$latch" 2>/dev/null
    log "spawn-failed pct=$pct sid=$sid"
  fi
}

scan_once() {
  [ -e "$STATE_DIR/DISABLED" ] && return 0
  [ -d "$SESS_DIR" ] || return 0
  # newest first; only look at a bounded number of recent rollouts
  while IFS= read -r f; do
    [ -n "$f" ] && handle_session "$f"
  done < <(find "$SESS_DIR" -name "rollout-*.jsonl" -type f 2>/dev/null | xargs ls -t 2>/dev/null | head -20)
}

if [ -n "${CODEX_ROLLOVER_ONCE:-}" ]; then
  scan_once
  exit 0
fi

log "watcher started (threshold=${THRESHOLD}% poll=${POLL}s)"
while :; do
  scan_once
  sleep "$POLL"
done
