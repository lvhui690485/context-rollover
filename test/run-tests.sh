#!/usr/bin/env bash
#
# run-tests.sh — sandboxed tests for the rollover hook. Opens ZERO real windows:
# every case either stays below threshold, exits at a circuit breaker before the
# spawn step, or runs in dry-run. Uses an isolated CLAUDE_CONFIG_DIR + a fake
# claude-hud cache so nothing touches your real Claude Code state.
#
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/hud-context-rollover.sh"
pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }

bash -n "$HOOK" && ok "syntax" || no "syntax"

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

rm -rf "$T"
echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
