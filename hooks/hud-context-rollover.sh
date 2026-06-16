#!/usr/bin/env bash
#
# hud-context-rollover.sh — a Claude Code PostToolUse hook.
#
# When the current Claude Code session's context usage crosses a threshold
# (default 60%), this hook hands the work off to a fresh window:
#   1. reads the live context percentage that the claude-hud plugin caches to
#      disk for THIS session (keyed by sha256 of the transcript path),
#   2. spawns a NEW, lean `claude` session in a split pane / new window, cd'd to
#      the same repo, seeded with a prompt to continue from the handoff,
#   3. tells THIS session to stop ({"continue": false}) so you hand off cleanly
#      instead of grinding on with a nearly-full context window.
#
# It fires at most once per session (latch file). Any parse/IO failure is a
# no-op: the hook NEVER stops a session unless it has positively decided to and
# a new window actually opened.
#
# Requirements: macOS, python3, the claude-hud plugin (provides the context%
# signal on disk). Terminal backends: tmux / iTerm2 / Ghostty / Apple Terminal.
#
# Safety nets (learned the hard way — see README "The fork-bomb story"):
#   - child env is stripped of HUD_ROLLOVER_* so a tuning value can't propagate
#   - global cooldown caps spawn RATE across all sessions
#   - auto-self-disable trips a kill switch if too many spawns happen fast
#   - a file kill switch halts even already-running sessions
#
# Env knobs (see README):
#   HUD_ROLLOVER_THRESHOLD     percent, default 60
#   HUD_ROLLOVER_COOLDOWN      seconds between spawns globally, default 180
#   HUD_ROLLOVER_MAX_BURST     spawns-in-10min that auto-trips the kill switch, default 5
#   HUD_ROLLOVER_SEED          override the seed prompt for the new session
#   HUD_ROLLOVER_DRYRUN=1      print the decision, do NOT spawn, do NOT stop
#   HUD_ROLLOVER_REFRESH_HANDOFF=1  run a repo handoff refresher before spawning (opt-in)
#   HUD_ROLLOVER_DISABLE=1     hard off for this invocation
#
# MIT License. https://github.com/lvhui690485/claude-context-rollover
#
set -u

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATE_DIR="$CONFIG_DIR/state/hud-rollover"

# FILE-BASED KILL SWITCH — checked on every invocation (script re-read from disk),
# so it halts even already-running sessions that loaded this hook into memory.
[ -e "$STATE_DIR/DISABLED" ] && exit 0
[ -n "${HUD_ROLLOVER_DISABLE:-}" ] && exit 0

THRESHOLD="${HUD_ROLLOVER_THRESHOLD:-60}"
CACHE_DIR="$CONFIG_DIR/plugins/claude-hud/context-cache"
LATCH_DIR="$STATE_DIR"
LOG="$LATCH_DIR/rollover.log"

PY="$(command -v python3 || echo /usr/bin/python3)"

# --- read hook stdin ---------------------------------------------------------
json="$(cat 2>/dev/null)"
[ -n "$json" ] || exit 0

# tab-separated so a path containing spaces is not word-split into the wrong field
IFS=$'\t' read -r transcript cwd session_id <<EOF2
$(printf '%s' "$json" | "$PY" -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print("\t".join([(d.get("transcript_path") or "").strip(), (d.get("cwd") or "").strip(), (d.get("session_id") or "").strip()]))
except Exception:
    print("\t\t")' 2>/dev/null)
EOF2

[ -n "$transcript" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# --- locate this session's claude-hud cache (sha256 of transcript path) ------
hash="$(printf '%s' "$transcript" | shasum -a 256 2>/dev/null | awk '{print $1}')"
[ -n "$hash" ] || exit 0
cache_file="$CACHE_DIR/$hash.json"
[ -f "$cache_file" ] || exit 0

used="$("$PY" -c 'import sys,json
try:
    print(int(round(float(json.load(open(sys.argv[1])).get("used_percentage",0)))))
except Exception:
    print(-1)' "$cache_file" 2>/dev/null)"
case "$used" in ''|*[!0-9-]*) exit 0;; esac
[ "$used" -ge 0 ] 2>/dev/null || exit 0

# --- threshold gate ----------------------------------------------------------
if [ "$used" -lt "$THRESHOLD" ]; then
  exit 0
fi

# --- fire-once latch (per session transcript) --------------------------------
mkdir -p "$LATCH_DIR" 2>/dev/null
latch="$LATCH_DIR/$hash.fired"
if [ -e "$latch" ]; then
  exit 0
fi
: > "$latch" 2>/dev/null

stamp="$(date '+%F %T' 2>/dev/null)"
now_epoch="$(date +%s 2>/dev/null)"

# --- adaptive seed prompt for the new (lean) session -------------------------
# Priority: HUD_ROLLOVER_SEED override > repo-harness resume.md > self-contained
# handoff auto-generated from the transcript + git state.
resume_file="$cwd/.ai/harness/handoff/resume.md"
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
handoff_gen="$SELF_DIR/lib/rollover-handoff.py"
[ -f "$handoff_gen" ] || handoff_gen="$CONFIG_DIR/hooks/lib/rollover-handoff.py"
# repo-local, stable, visible path (like repo-harness's resume.md)
handoff_rel="${HUD_ROLLOVER_HANDOFF_PATH:-.claude/rollover-handoff.md}"
handoff_file="$cwd/$handoff_rel"

if [ -n "${HUD_ROLLOVER_SEED:-}" ]; then
  seed="$HUD_ROLLOVER_SEED"
elif [ -f "$resume_file" ]; then
  seed="The previous session reached ${used}% context and handed off to this window. First read .ai/harness/handoff/resume.md and tasks/current.md, reconcile against the live repo (active plan, git status), then continue from the next step. Do not redo completed work."
elif [ -f "$handoff_gen" ] && mkdir -p "$(dirname "$handoff_file")" 2>/dev/null && "$PY" "$handoff_gen" "$transcript" "$cwd" "$used" "$handoff_file" >/dev/null 2>&1 && [ -s "$handoff_file" ]; then
  # self-contained handoff written into the repo (transcript + git state).
  # Keep git clean without touching a tracked .gitignore: use info/exclude.
  # `[ -e .git ]` (file in worktrees, dir in normal repos) + rev-parse resolves
  # the correct exclude path in both layouts.
  if [ -e "$cwd/.git" ] && [ -z "${HUD_ROLLOVER_NO_GITIGNORE:-}" ]; then
    excl="$(git -C "$cwd" rev-parse --git-path info/exclude 2>/dev/null)"
    if [ -n "$excl" ]; then
      case "$excl" in /*) :;; *) excl="$cwd/$excl";; esac
      mkdir -p "$(dirname "$excl")" 2>/dev/null
      grep -qxF "$handoff_rel" "$excl" 2>/dev/null || printf '%s\n' "$handoff_rel" >> "$excl" 2>/dev/null || true
    fi
  fi
  seed="The previous session reached ${used}% context and handed off to this window. First read the handoff file ./$handoff_rel (it captures the task, recent actions, files touched, and the git diff), then continue the in-progress work from where it left off. Do not redo completed work."
else
  seed="The previous session reached ${used}% context and handed off to this window. Reconstruct where it left off from git log/status and the uncommitted diff, then continue from the next step. Do not redo completed work."
fi

# Make the seed safe inside single quotes regardless of its content.
esc_seed="$(printf '%s' "$seed" | sed "s/'/'\\\\''/g")"

# command the new pane runs: a FRESH claude (no --continue/--fork) = lean context.
# CRITICAL: strip all HUD_ROLLOVER_* from the child env so a tuning value (or any
# inherited value) can NEVER propagate into the spawned session — root-cause fix
# for the fork-bomb.
sanitize='unset HUD_ROLLOVER_THRESHOLD HUD_ROLLOVER_DRYRUN HUD_ROLLOVER_REFRESH_HANDOFF HUD_ROLLOVER_DISABLE HUD_ROLLOVER_COOLDOWN HUD_ROLLOVER_MAX_BURST HUD_ROLLOVER_SEED'
# `open` hands our full env to the spawned app. If the inherited CLAUDE_CONFIG_DIR
# points at a dir that no longer exists (stale/temp/deleted), the child claude
# can't find its login and re-prompts auth. Evaluate this in the CHILD shell at
# startup (single-quoted so the hook does NOT expand it) so even a dir deleted
# after spawn is caught — then it falls back to the default ~/.claude creds.
ccd_guard='[ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ ! -d "${CLAUDE_CONFIG_DIR:-}" ] && unset CLAUDE_CONFIG_DIR'
newcmd="$ccd_guard; $sanitize; cd $(printf '%q' "$cwd") && claude '$esc_seed'"

# --- dry run: decide but do nothing irreversible (no log, no breakers) --------
if [ -n "${HUD_ROLLOVER_DRYRUN:-}" ]; then
  {
    echo "[hud-rollover dry-run] used=${used}% >= threshold=${THRESHOLD}%"
    echo "[hud-rollover dry-run] cwd=$cwd"
    echo "[hud-rollover dry-run] handoff resume.md present: $([ -f "$resume_file" ] && echo yes || echo no)"
    echo "[hud-rollover dry-run] would run: $newcmd"
    echo "[hud-rollover dry-run] would emit: {\"continue\": false}"
  } >&2
  rm -f "$latch" 2>/dev/null   # don't consume the latch during a dry run
  exit 0
fi

# --- CIRCUIT BREAKER 1: global cooldown (cap spawn RATE across all sessions) --
# No more than one window per COOLDOWN seconds globally, so even a broken guard
# cannot fork-bomb.
COOLDOWN="${HUD_ROLLOVER_COOLDOWN:-180}"
cdfile="$LATCH_DIR/last-spawn.epoch"
if [ -f "$cdfile" ]; then
  last="$(cat "$cdfile" 2>/dev/null)"; case "$last" in ''|*[!0-9]*) last=0;; esac
  if [ $(( now_epoch - last )) -lt "$COOLDOWN" ]; then
    printf '%s COOLDOWN-skip used=%s%% thr=%s%% cwd=%s session=%s\n' "$stamp" "$used" "$THRESHOLD" "$cwd" "$session_id" >> "$LOG" 2>/dev/null
    rm -f "$latch" 2>/dev/null   # allow this session to retry once cooldown clears
    exit 0
  fi
fi

# --- CIRCUIT BREAKER 2: auto-self-disable on suspected cascade ----------------
# If >= MAXBURST spawns were logged in the last 10 minutes, something is looping:
# write the kill switch and stop. Re-arm by deleting the DISABLED file.
MAXBURST="${HUD_ROLLOVER_MAX_BURST:-5}"
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
print(c)' "$LOG" "$now_epoch" 2>/dev/null)"
case "$recent" in ''|*[!0-9]*) recent=0;; esac
if [ "$recent" -ge "$MAXBURST" ]; then
  : > "$LATCH_DIR/DISABLED" 2>/dev/null
  printf '%s AUTO-DISABLE burst=%s in 10min — kill switch written\n' "$stamp" "$recent" >> "$LOG" 2>/dev/null
  rm -f "$latch" 2>/dev/null
  exit 0
fi

printf '%s SPAWN used=%s%% thr=%s%% cwd=%s session=%s\n' "$stamp" "$used" "$THRESHOLD" "$cwd" "$session_id" >> "$LOG" 2>/dev/null

# --- optional: refresh a repo handoff before spawning (opt-in) ----------------
# repo-harness ships .ai/hooks/stop-orchestrator.sh which (re)writes resume.md.
orch="$cwd/.ai/hooks/stop-orchestrator.sh"
if [ -n "${HUD_ROLLOVER_REFRESH_HANDOFF:-}" ] && [ -x "$orch" ]; then
  printf '%s' "$json" | ( cd "$cwd" && timeout 20 "$orch" >/dev/null 2>&1 ) || true
fi

# --- spawn the new view (tmux > iTerm2 > Ghostty > Apple Terminal) ------------
spawned=0
if [ -n "${TMUX:-}" ]; then
  if tmux split-window -h -c "$cwd" "$newcmd" 2>/dev/null \
     || { tmux split-window -h -c "$cwd" 2>/dev/null && tmux send-keys "$newcmd" Enter 2>/dev/null; }; then
    spawned=1
  fi
fi

if [ "$spawned" -eq 0 ] && [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
  if osascript \
      -e 'on run argv' \
      -e 'set cmd to item 1 of argv' \
      -e 'tell application "iTerm"' \
      -e '  activate' \
      -e '  tell current session of current window to set s to (split vertically with default profile)' \
      -e '  tell s to write text cmd' \
      -e 'end tell' \
      -e 'end run' \
      "$newcmd" >/dev/null 2>&1; then
    spawned=1
  fi
fi

# Ghostty has no split API, but `open -na Ghostty.app --args -e <cmd>` opens a window.
if [ "$spawned" -eq 0 ] && { [ "${TERM_PROGRAM:-}" = "ghostty" ] || [ -d "/Applications/Ghostty.app" ]; }; then
  if open -na Ghostty.app --args -e zsh -lc "$newcmd" >/dev/null 2>&1; then
    spawned=1
  fi
fi

if [ "$spawned" -eq 0 ]; then
  if osascript \
      -e 'on run argv' \
      -e 'set cmd to item 1 of argv' \
      -e 'tell application "Terminal"' \
      -e '  activate' \
      -e '  do script cmd' \
      -e 'end tell' \
      -e 'end run' \
      "$newcmd" >/dev/null 2>&1; then
    spawned=1
  fi
fi

# --- stop THIS session only if the handoff window actually opened -------------
if [ "$spawned" -eq 1 ]; then
  date +%s > "$cdfile" 2>/dev/null          # arm the global cooldown
  printf '{"continue": false, "stopReason": "Context %s%% >= %s%% — handed off to a fresh window. This session is stopping.", "systemMessage": "🪟 Context %s%% >= %s%% — opened a fresh window to continue; this session is stopping."}\n' \
    "$used" "$THRESHOLD" "$used" "$THRESHOLD"
  exit 0
fi

# spawn failed: release latch, do NOT stop the session
rm -f "$latch" 2>/dev/null
echo "[hud-rollover] threshold hit but could not open a new view; session left running." >&2
exit 0
