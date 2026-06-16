#!/usr/bin/env python3
"""
rollover-handoff.py — generate a lightweight, file-backed handoff for a fresh
coding-agent session, so a rolled-over task can be continued without the
original conversation's memory.

Supports both transcript formats:
  - Claude Code  : <session>.jsonl  (user/assistant messages with content blocks)
  - Codex CLI    : rollout-*.jsonl  (session_meta / response_item / event_msg)

Writes a markdown handoff: the human's recent requests, the plan it was
following (Codex update_plan), what it was doing, files it touched, and the git
diff at the moment of handoff.

Usage:  rollover-handoff.py <transcript.jsonl> <cwd> <used_percent> <out.md>
Prints the out path on success; exits non-zero (and writes nothing) on failure.
"""
import json
import re
import subprocess
import sys

MAX_HUMAN = 5
MAX_ACTIONS = 18
MAX_FILES = 40
TEXT_CLIP = 700


def clip(s, n=TEXT_CLIP):
    s = " ".join((s or "").split())
    return s if len(s) <= n else s[: n - 1] + "…"


# ---------- format detection ------------------------------------------------

def detect_format(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if '"session_meta"' in line or '"response_item"' in line \
                        or '"rollout"' in line:
                    return "codex"
                if i > 40:
                    break
    except FileNotFoundError:
        return None
    return "claude"


# ---------- Claude Code transcript ------------------------------------------

def _blocks(content):
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    if isinstance(content, list):
        return [b for b in content if isinstance(b, dict)]
    return []


def _claude_action(name, inp):
    inp = inp if isinstance(inp, dict) else {}
    if name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        return f"{name} {inp.get('file_path') or inp.get('notebook_path') or ''}".strip()
    if name == "Bash":
        return f"Bash: {clip(inp.get('command', ''), 120)}"
    if name in ("Read", "Grep", "Glob"):
        return f"{name} {inp.get('file_path') or inp.get('pattern') or inp.get('path') or ''}".strip()
    if name == "Task":
        return f"Task: {clip(inp.get('description', ''), 80)}"
    return name


def parse_claude(path):
    human, actions, files, last_text = [], [], [], ""
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            msg = obj.get("message", obj)
            if not isinstance(msg, dict):
                continue
            role = msg.get("role") or obj.get("type")
            bs = _blocks(msg.get("content"))
            if role == "user":
                txt = " ".join(b.get("text", "") for b in bs if b.get("type") == "text").strip()
                if txt and not txt.startswith("<"):
                    human.append(clip(txt, 400))
            elif role == "assistant":
                for b in bs:
                    if b.get("type") == "text" and b.get("text", "").strip():
                        last_text = clip(b["text"], TEXT_CLIP)
                    elif b.get("type") == "tool_use":
                        name, inp = b.get("name", "?"), b.get("input", {})
                        actions.append(_claude_action(name, inp))
                        if name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
                            fp = (inp or {}).get("file_path") or (inp or {}).get("notebook_path")
                            if fp and fp not in files:
                                files.append(fp)
    return human, actions, files, last_text, None


# ---------- Codex CLI rollout ------------------------------------------------

_PATCH_FILE = re.compile(r"\*\*\* (?:Update|Add|Delete) File: (.+)")

# Codex injects its preamble (AGENTS.md, environment_context, user_instructions)
# as user-role messages; skip those so only real human turns are captured.
def _is_codex_injected(txt):
    if txt.startswith("<"):
        return True
    head = txt[:80]
    if head.startswith("# AGENTS.md") or head.startswith("# Codex"):
        return True
    return any(tag in txt for tag in
               ("<environment_context>", "<user_instructions>", "<INSTRUCTIONS>"))


def _patch_files(patch_text):
    return [m.strip() for m in _PATCH_FILE.findall(patch_text or "")]


def parse_codex(path):
    human, actions, files, last_text, plan = [], [], [], "", None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("type") != "response_item":
                continue
            p = obj.get("payload", {})
            if not isinstance(p, dict):
                continue
            pt = p.get("type")
            if pt == "message":
                role = p.get("role")
                txt = " ".join(
                    b.get("text", "") for b in p.get("content", [])
                    if isinstance(b, dict) and b.get("type") in ("input_text", "output_text", "text")
                ).strip()
                if not txt:
                    continue
                if role == "user" and not _is_codex_injected(txt):
                    human.append(clip(txt, 400))
                elif role == "assistant":
                    last_text = clip(txt, TEXT_CLIP)
            elif pt == "function_call":
                name = p.get("name", "")
                if name == "update_plan":
                    try:
                        plan = json.loads(p.get("arguments", "{}")).get("plan")
                    except Exception:
                        pass
                    actions.append("update_plan")
                elif name == "shell":
                    try:
                        cmd = json.loads(p.get("arguments", "{}")).get("command")
                        if isinstance(cmd, list):
                            cmd = " ".join(cmd)
                        actions.append("shell: " + clip(cmd or "", 120))
                        for fp in _patch_files(cmd or ""):
                            if fp not in files:
                                files.append(fp)
                    except Exception:
                        actions.append("shell")
                else:
                    actions.append(name or "function_call")
            elif pt == "custom_tool_call":
                name = p.get("name", "")
                actions.append(name or "custom_tool_call")
                if name == "apply_patch":
                    for fp in _patch_files(p.get("input", "")):
                        if fp not in files:
                            files.append(fp)
    return human, actions, files, last_text, plan


# ---------- git + render -----------------------------------------------------

def git(cwd, *args):
    try:
        return subprocess.run(["git", "-C", cwd, *args],
                              capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        return ""


def main():
    if len(sys.argv) < 5:
        return 1
    transcript, cwd, used, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

    fmt = detect_format(transcript)
    if fmt is None:
        return 1
    human, actions, files, last_text, plan = (parse_codex if fmt == "codex" else parse_claude)(transcript)

    status = git(cwd, "status", "--short")
    diffstat = git(cwd, "diff", "--stat")
    branch = git(cwd, "rev-parse", "--abbrev-ref", "HEAD")
    recent_commits = git(cwd, "log", "--oneline", "-5")

    L = ["# Rollover handoff (auto-generated)\n"]
    L.append(
        f"> The previous {fmt} session reached **{used}%** context and handed off to "
        f"this window. It has **no memory** of that conversation — this file and the "
        f"repo are the handoff. Read it, then continue from where it left off. Do not "
        f"redo completed work.\n"
    )
    if branch:
        L.append(f"- **Branch:** `{branch}`")
    L.append(f"- **Working dir:** `{cwd}`\n")

    L.append("## The task (most recent human requests)\n")
    if human:
        L += [f"- {h}" for h in human[-MAX_HUMAN:]]
    else:
        L.append("- _(none captured — infer from the plan/diff below)_")
    L.append("")

    if plan:
        L.append("## The plan it was following\n")
        for step in plan:
            if isinstance(step, dict):
                box = {"completed": "[x]", "in_progress": "[~]"}.get(step.get("status"), "[ ]")
                L.append(f"- {box} {step.get('step', '')}")
        L.append("")

    if last_text:
        L.append("## Where it left off (its last message)\n")
        L.append(f"> {last_text}\n")

    L.append("## Recent actions it took\n")
    L += [f"- {a}" for a in actions[-MAX_ACTIONS:]] or ["- _(none captured)_"]
    L.append("")

    if files:
        L.append("## Files it edited this session\n")
        L += [f"- `{fp}`" for fp in files[:MAX_FILES]]
        L.append("")

    L.append("## Git state at handoff\n")
    if status:
        L.append("Uncommitted changes (`git status --short`):\n\n```")
        L.append(status[:4000])
        L.append("```")
    else:
        L.append("_Working tree clean (no uncommitted changes)._")
    if diffstat:
        L.append("\n`git diff --stat`:\n\n```")
        L.append(diffstat[:2000])
        L.append("```")
    if recent_commits:
        L.append("\nRecent commits:\n\n```")
        L.append(recent_commits)
        L.append("```")
    L.append("")

    L.append("## Continue from here\n")
    L.append("1. Read the requests + plan above and the uncommitted diff to see the task and how far it got.")
    L.append("2. Continue from the next step. Preserve the approach already in progress; don't restart settled choices.")
    L.append("3. If intent is genuinely unclear from the diff + requests, ask before making large changes.")

    try:
        with open(out, "w", encoding="utf-8") as f:
            f.write("\n".join(L) + "\n")
    except Exception:
        return 1
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
