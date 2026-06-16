#!/usr/bin/env bash
#
# run-tests.sh — sandboxed tests for the rollover hook. Opens ZERO real windows:
# every case either stays below threshold, exits at a circuit breaker before the
# spawn step, or runs in dry-run. Uses an isolated CLAUDE_CONFIG_DIR + a fake
# claude-hud cache so nothing touches your real Claude Code state.
#
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/hooks/hud-context-rollover.sh"
SS="$ROOT/hooks/session-start-handoff.sh"
pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }

bash -n "$HOOK" && ok "rollover syntax" || no "rollover syntax"
bash -n "$SS" && ok "session-start syntax" || no "session-start syntax"

# lint: a $var directly followed by a non-ASCII byte (e.g. Chinese '（') makes
# bash glue the byte onto the name → 'unbound variable' under set -u. Brace it.
if grep -rlP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' "$ROOT/hooks" "$ROOT/codex" >/dev/null 2>&1; then
  no "unbraced \$var glued to non-ASCII (use \${var}): $(grep -rlP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' "$ROOT/hooks" "$ROOT/codex" | tr '\n' ' ')"
else
  ok "no \$var glued to non-ASCII text"
fi

T="$(mktemp -d)"; faketx="$T/s.jsonl"; : > "$faketx"
h=$(printf '%s' "$faketx" | shasum -a 256 | awk '{print $1}')
mkdir -p "$T/plugins/claude-hud/context-cache" "$T/state/hud-rollover"
mkcache(){ printf '{"used_percentage":%s,"context_window_size":1000000}' "$1" > "$T/plugins/claude-hud/context-cache/$h.json"; }
run(){ printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$faketx" "$PWD" "$1"; }
LOG="$T/state/hud-rollover/rollover.log"

echo "A) below threshold -> silent"
mkcache 40
out=$(run a | CLAUDE_CONFIG_DIR="$T" "$HOOK" 2>&1); [ -z "$out" ] && ok "no output" || no "got: $out"

echo "B) env sanitized + config-dir guard present (dry-run)"
mkcache 70
nc=$(run b | CLAUDE_CONFIG_DIR="$T" HUD_ROLLOVER_DRYRUN=1 "$HOOK" 2>&1 | grep "would run")
echo "$nc" | grep -q "unset HUD_ROLLOVER" && ok "HUD_ROLLOVER_* unset" || no "missing unset"
echo "$nc" | grep -q "CLAUDE_CONFIG_DIR" && ok "config-dir guard present" || no "missing guard"

echo "C) seed override respected (dry-run)"
nc=$(run c | CLAUDE_CONFIG_DIR="$T" HUD_ROLLOVER_DRYRUN=1 HUD_ROLLOVER_SEED="CUSTOM_SEED_X" "$HOOK" 2>&1 | grep "would run")
echo "$nc" | grep -q "CUSTOM_SEED_X" && ok "custom seed used" || no "seed not used"

echo "D) cooldown breaker -> skip before spawn"
mkcache 70; echo "$(date +%s)" > "$T/state/hud-rollover/last-spawn.epoch"
out=$(run d | CLAUDE_CONFIG_DIR="$T" "$HOOK" 2>&1)
tail -1 "$LOG" 2>/dev/null | grep -q COOLDOWN-skip && [ -z "$out" ] && ok "cooled down, no spawn" || no "cooldown failed"
rm -f "$T/state/hud-rollover/last-spawn.epoch"

echo "E) burst auto-disable writes kill switch"
now=$(date +%s)
for i in 1 2 3 4 5; do printf '%s SPAWN x\n' "$(date -r $((now-60*i)) '+%F %T')" >> "$LOG"; done
mkcache 70
run e | CLAUDE_CONFIG_DIR="$T" "$HOOK" >/dev/null 2>&1
[ -e "$T/state/hud-rollover/DISABLED" ] && ok "DISABLED written" || no "no auto-disable"

echo "F) DISABLED kill switch beats everything"
mkcache 99
out=$(run f | CLAUDE_CONFIG_DIR="$T" HUD_ROLLOVER_THRESHOLD=1 "$HOOK" 2>&1)
[ -z "$out" ] && ok "halted by kill switch" || no "fired despite DISABLED"

echo "G) self-contained handoff lands in the repo (.claude/rollover-handoff.md)"
rm -f "$T/state/hud-rollover/DISABLED"
REPO="$T/proj"; mkdir -p "$REPO"; ( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t )
cat > "$faketx" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"REFACTOR_TASK_MARKER refactor the auth module to async/await"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"working on it"},{"type":"tool_use","name":"Edit","input":{"file_path":"src/auth/login.ts"}}]}}
JSONL
mkcache 70
runR(){ printf '{"transcript_path":"%s","cwd":"%s","session_id":"%s"}' "$faketx" "$REPO" "$1"; }
nc=$(runR g | CLAUDE_CONFIG_DIR="$T" HUD_ROLLOVER_DRYRUN=1 "$HOOK" 2>&1 | grep "would run")
hf="$REPO/.claude/rollover-handoff.md"
[ -s "$hf" ] && ok "handoff written into repo .claude/" || no "no handoff file in repo"
grep -q "REFACTOR_TASK_MARKER" "$hf" 2>/dev/null && ok "task captured in handoff" || no "task missing"
grep -q "src/auth/login.ts" "$hf" 2>/dev/null && ok "edited file captured" || no "file missing"
echo "$nc" | grep -q ".claude/rollover-handoff.md" && ok "seed points at repo handoff" || no "seed missing handoff path"
grep -qxF ".claude/rollover-handoff.md" "$REPO/.git/info/exclude" 2>/dev/null && ok "added to .git/info/exclude (git stays clean)" || no "not git-excluded"

echo "H) SessionStart injects a fresh handoff once, skips stale/consumed"
ssrun(){ printf '{"cwd":"%s","session_id":"%s","source":"startup"}' "$REPO" "$1"; }
# fresh handoff from G is present; first start should inject it
out=$(ssrun h1 | CLAUDE_CONFIG_DIR="$T" bash "$SS" 2>/dev/null)
echo "$out" | grep -q "additionalContext" && echo "$out" | grep -q "REFACTOR_TASK_MARKER" && ok "injects handoff into context" || no "did not inject"
# second start (same mtime) → consumed, no inject
out2=$(ssrun h2 | CLAUDE_CONFIG_DIR="$T" bash "$SS" 2>/dev/null)
[ -z "$out2" ] && ok "consume-once: second start no inject" || no "re-injected"
# stale handoff (old mtime) → skip
touch -t 202001010000 "$hf"; rm -f "$T/state/hud-rollover/injected-"*
out3=$(ssrun h3 | CLAUDE_CONFIG_DIR="$T" HUD_ROLLOVER_INJECT_MAXAGE=900 bash "$SS" 2>/dev/null)
[ -z "$out3" ] && ok "freshness: stale handoff skipped" || no "injected stale handoff"

echo "I) path with a space still resolves (tab-separated field read)"
SP="$T/dir with space"; mkdir -p "$SP"
sptx="$SP/s.jsonl"; : > "$sptx"
sph=$(printf '%s' "$sptx" | shasum -a 256 | awk '{print $1}')
printf '{"used_percentage":70,"context_window_size":1000000}' > "$T/plugins/claude-hud/context-cache/$sph.json"
out=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"i"}' "$sptx" "$SP" \
  | CLAUDE_CONFIG_DIR="$T" HUD_ROLLOVER_DRYRUN=1 "$HOOK" 2>&1)
echo "$out" | grep -q "would run" && ok "space path reaches decision (not mis-split)" || no "space path mis-split → no-op"

echo "J) handoff is excluded via the correct path in a git worktree"
MAIN="$T/main"; WT="$T/wt"
( mkdir -p "$MAIN" && cd "$MAIN" && git init -q && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m init && git worktree add -q "$WT" 2>/dev/null )
wttx="$T/wt.jsonl"; : > "$wttx"
wth=$(printf '%s' "$wttx" | shasum -a 256 | awk '{print $1}')
printf '{"used_percentage":70,"context_window_size":1000000}' > "$T/plugins/claude-hud/context-cache/$wth.json"
printf '{"transcript_path":"%s","cwd":"%s","session_id":"j"}' "$wttx" "$WT" \
  | CLAUDE_CONFIG_DIR="$T" HUD_ROLLOVER_DRYRUN=1 "$HOOK" >/dev/null 2>&1
excl="$(git -C "$WT" rev-parse --git-path info/exclude 2>/dev/null)"
case "$excl" in /*) :;; *) excl="$WT/$excl";; esac
grep -qxF ".claude/rollover-handoff.md" "$excl" 2>/dev/null && ok "worktree exclude written (.git is a file there)" || no "worktree exclude missed"
[ ! -d "$WT/.git" ] && ok "confirmed .git is a file in the worktree" || no "test setup: .git is a dir"

rm -rf "$T"
echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
