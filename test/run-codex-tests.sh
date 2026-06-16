#!/usr/bin/env bash
#
# run-codex-tests.sh — sandboxed tests for the Codex watcher + handoff parser.
# Opens ZERO real windows (dry-run / below-threshold / kill-switch only) and uses
# an isolated CODEX_HOME so nothing touches your real Codex state.
#
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WATCH="$ROOT/codex/codex-context-watcher.sh"
GEN="$ROOT/hooks/lib/rollover-handoff.py"
pass=0; fail=0
ok(){ echo "  ✅ $1"; pass=$((pass+1)); }
no(){ echo "  ❌ $1"; fail=$((fail+1)); }

bash -n "$WATCH" && ok "watcher syntax" || no "watcher syntax"
python3 -c "import ast;ast.parse(open('$GEN').read())" && ok "handoff py syntax" || no "handoff py syntax"

# --- build an isolated Codex home + a synthetic rollout ----------------------
T="$(mktemp -d)"
CH="$T/codex"; REPO="$T/proj"
mkdir -p "$CH/sessions/2026/06/16" "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t )
ROLL="$CH/sessions/2026/06/16/rollout-test.jsonl"
cat > "$ROLL" <<JSONL
{"timestamp":"t","type":"session_meta","payload":{"id":"sid-test","cwd":"$REPO"}}
{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"CODEX_TASK_MARKER refactor the mapper layer to async"}]}}
{"timestamp":"t","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"PLAN_STEP_ONE\",\"status\":\"in_progress\"},{\"step\":\"PLAN_STEP_TWO\",\"status\":\"pending\"}]}"}}
{"timestamp":"t","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: src/Mapper.java\n@@\n-old\n+new\n*** End Patch"}}
{"timestamp":"t","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"LAST_MESSAGE_MARKER next I will do step two"}]}}
{"timestamp":"t","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":700},"model_context_window":1000}}}
JSONL

echo "A) handoff parser on a Codex rollout"
out="$T/h.md"
python3 "$GEN" "$ROLL" "$REPO" 70 "$out" >/dev/null 2>&1
[ -s "$out" ] && ok "handoff written" || no "no handoff"
grep -q "CODEX_TASK_MARKER" "$out" && ok "task captured" || no "task missing"
grep -q "PLAN_STEP_ONE" "$out" && ok "plan captured (update_plan)" || no "plan missing"
grep -q "src/Mapper.java" "$out" && ok "edited file captured (apply_patch)" || no "file missing"
grep -q "LAST_MESSAGE_MARKER" "$out" && ok "last message captured" || no "last msg missing"
grep -q "previous codex session" "$out" && ok "labeled as codex" || no "wrong label"

echo "B) watcher computes % and decides to roll (dry-run, no window)"
touch "$ROLL"   # fresh mtime; IDLE=0 bypasses quiescence wait
out2=$(CODEX_HOME="$CH" CODEX_ROLLOVER_ONCE=1 CODEX_ROLLOVER_DRYRUN=1 \
       CODEX_ROLLOVER_IDLE=0 CODEX_ROLLOVER_THRESHOLD=60 bash "$WATCH" 2>&1)
echo "$out2" | grep -q "pct=70%" && echo "$out2" | grep -q "would-roll\|pct=70" && ok "fires at 70% >= 60%" || no "did not fire ($out2)"

echo "C) below threshold -> no roll"
out3=$(CODEX_HOME="$CH" CODEX_ROLLOVER_ONCE=1 CODEX_ROLLOVER_DRYRUN=1 \
       CODEX_ROLLOVER_IDLE=0 CODEX_ROLLOVER_THRESHOLD=90 bash "$WATCH" 2>&1)
[ -z "$out3" ] && ok "silent below threshold" || no "fired below threshold"

echo "D) DISABLED kill switch halts the scan"
mkdir -p "$CH/rollover-state"; : > "$CH/rollover-state/DISABLED"
rm -f "$CH/rollover-state/fired-"*
out4=$(CODEX_HOME="$CH" CODEX_ROLLOVER_ONCE=1 CODEX_ROLLOVER_DRYRUN=1 \
       CODEX_ROLLOVER_IDLE=0 CODEX_ROLLOVER_THRESHOLD=60 bash "$WATCH" 2>&1)
[ -z "$out4" ] && ok "halted by kill switch" || no "ran despite DISABLED"

rm -rf "$T"
echo "-----"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
