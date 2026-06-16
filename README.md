# context-rollover

**When a Claude Code session fills up its context window, hand the work off to a
fresh window — automatically.**

At a configurable threshold (default **60%** of the context window), this hook:

1. opens a **new, lean `claude` session** in a split pane / new window, in the
   same repo, seeded with a prompt to continue from where you left off, and
2. **stops the current session** cleanly, so you don't keep grinding with a
   nearly-full window (slower, dumber, more expensive).

You keep working in the new window. The baton is passed. No manual `/compact`, no
copy-pasting context, no babysitting.

The new session has **no memory** of the old conversation (that's the point —
lean context). So the handoff is file-backed; see below for how the new window
knows what to continue.

---

## Handoff: how the new window knows what to continue

Since the new session starts fresh, the task state has to reach it through files,
not memory. The hook picks the richest handoff available, in this order:

1. **`HUD_ROLLOVER_SEED`** — if you set it, that string is the new session's
   prompt verbatim.
2. **repo-harness handoff** — if `.ai/harness/handoff/resume.md` exists
   ([repo-harness](https://github.com/Ancienttwo/repo-harness) writes it
   continuously and injects it on `SessionStart`), the new session is pointed at
   it plus `tasks/current.md`. Most precise.
3. **Self-contained handoff (built in, no dependencies)** — otherwise the hook
   reads the **current session's transcript** and writes a markdown handoff into
   the repo at **`.claude/rollover-handoff.md`** (like repo-harness's `resume.md`
   — a stable, visible, reviewable file that travels with the project),
   capturing:
   - the most recent **human requests** (the actual task intent),
   - the previous session's **last message** (usually "next I'll…"),
   - **recent actions** and the **files it edited**,
   - the **git diff/status** at the moment of handoff (the in-progress work).

   So even a half-finished refactor in a plain repo rolls over with the task,
   the plan, and the diff intact.

   To keep `git status` clean, the path is added to `.git/info/exclude` (a local,
   untracked ignore — your tracked `.gitignore` is never modified). Change the
   path with `HUD_ROLLOVER_HANDOFF_PATH`, or skip the exclude with
   `HUD_ROLLOVER_NO_GITIGNORE=1`.

### Two ways the new session gets it

- **Auto-injected (SessionStart hook).** A companion `SessionStart` hook
  (`session-start-handoff.sh`, installed automatically) reads the fresh handoff
  and injects it straight into the new session's context — so continuation does
  **not** depend on the seed prompt being followed. It injects **once** per
  handoff and only if it's recent (`HUD_ROLLOVER_INJECT_MAXAGE`, default 5 min),
  so old handoffs never leak into unrelated future sessions.
- **Seed prompt.** The new session is also told to read the handoff file first.
  Belt and suspenders — even if the SessionStart hook isn't active, the prompt
  still points the agent at the handoff.

---

## Why not just `/compact`?

`/compact` summarizes and keeps going in the *same* session — you stay near the
ceiling and the summary is lossy. Rolling to a **fresh** session instead means
the new agent starts with a clean, small context and pulls only what it needs
from the repo. It's a baton pass, not a cram.

It deliberately does **not** fork/`--continue` the old session (that would carry
the heavy context across and defeat the purpose).

---

## How it works

Claude Code doesn't expose a "context reached X%" hook event. But the
[claude-hud](https://github.com/jarrodwatts/claude-hud) status-line plugin writes
the live percentage to disk every render:

```
~/.claude/plugins/claude-hud/context-cache/<sha256(transcript_path)>.json
   → {"used_percentage": 62, "context_window_size": 1000000, ...}
```

So this tool runs as a **`PostToolUse` hook**: after each tool call it reads that
file for the current session, and if usage ≥ threshold it spawns the new window
and returns `{"continue": false}` to stop the current one.

```
PostToolUse ─▶ read claude-hud cache for this session
            ─▶ used% < threshold ?  ── yes ─▶ exit (near-zero cost)
                       │ no
                       ▼
            fire-once latch + cooldown + burst guard
                       ▼
            spawn fresh `claude` in a new pane (tmux/iTerm/Ghostty/Terminal)
                       ▼
            emit {"continue": false}  ─▶ current session stops
```

---

## Requirements

- **macOS** (terminal spawning uses `open`/AppleScript; tmux path is portable)
- **python3** (ships with macOS dev tools)
- **[claude-hud](https://github.com/jarrodwatts/claude-hud)** plugin installed and
  set as your status line — it's what persists the context% signal this hook reads
- a terminal it can drive: **tmux**, **iTerm2**, **Ghostty**, or **Apple Terminal**

## Install

```bash
git clone https://github.com/lvhui690485/context-rollover
cd context-rollover
./install.sh
```

This copies the hook into `~/.claude/hooks/` and registers a `PostToolUse` hook
in `~/.claude/settings.json` (backed up first, idempotent). It takes effect in
**new** Claude Code sessions.

Uninstall: `./uninstall.sh`.

## Configuration

Set env vars in the hook command inside `~/.claude/settings.json`
(e.g. `"command": "HUD_ROLLOVER_THRESHOLD=70 HUD_ROLLOVER_COOLDOWN=300 /Users/you/.claude/hooks/hud-context-rollover.sh"`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `HUD_ROLLOVER_THRESHOLD` | `60` | Context % that triggers a rollover |
| `HUD_ROLLOVER_COOLDOWN` | `180` | Min seconds between spawns, globally |
| `HUD_ROLLOVER_MAX_BURST` | `5` | Spawns within 10 min that auto-trip the kill switch |
| `HUD_ROLLOVER_SEED` | _(auto)_ | Override the seed prompt for the new session |
| `HUD_ROLLOVER_HANDOFF_PATH` | `.claude/rollover-handoff.md` | Repo-relative path for the generated handoff |
| `HUD_ROLLOVER_NO_GITIGNORE` | _off_ | Don't add the handoff path to `.git/info/exclude` |
| `HUD_ROLLOVER_INJECT_MAXAGE` | `300` | SessionStart injects the handoff only if newer than this (seconds) |
| `HUD_ROLLOVER_REFRESH_HANDOFF` | _off_ | Run a repo handoff refresher before spawning (repo-harness) |
| `HUD_ROLLOVER_DRYRUN=1` | _off_ | Decide + log to stderr, but never spawn or stop |
| `HUD_ROLLOVER_DISABLE=1` | _off_ | Hard off for that invocation |

### Kill switch & logs

```bash
# stop instantly (affects even running sessions — script is re-read each call)
touch ~/.claude/state/hud-rollover/DISABLED
rm    ~/.claude/state/hud-rollover/DISABLED   # re-arm

# what fired, when
cat ~/.claude/state/hud-rollover/rollover.log
```

---

## Safety: the fork-bomb story

The first version shipped without guards. While testing with a lowered threshold,
the threshold env var **leaked through the spawn chain** (`open` passes the full
environment to the launched app → the child shell → the child `claude`). Every
fresh session inherited the low threshold, sat above it, and spawned another
window. ~17 windows in a couple of minutes. A self-replicating loop.

The fix is four layers, all in the hook now:

1. **Child env is sanitized** — the spawned command begins
   `unset HUD_ROLLOVER_*`, so no tuning value can ever propagate into the new
   session. (Root cause.)
2. **Global cooldown** — at most one spawn per `COOLDOWN` seconds across *all*
   sessions, so even a broken guard can't run away.
3. **Auto-self-disable** — if ≥ `MAX_BURST` spawns are logged within 10 minutes,
   the hook writes its own kill switch and stops.
4. **File kill switch** — `state/hud-rollover/DISABLED` is checked first on every
   invocation; because the hook script is re-read from disk each call, this halts
   even sessions that already loaded the hook into memory.

Bonus guard: the spawned shell checks `CLAUDE_CONFIG_DIR` at startup and drops it
if it points at a missing directory, so a stale value can't make the new `claude`
re-prompt authentication.

If you write self-spawning automation, copy these patterns: **never let tuning
env reach the process you spawn, always rate-limit, always have an auto-trip.**

---

## Codex CLI support

The same idea works for [Codex CLI](https://github.com/openai/codex) — with a
different trigger, because Codex has no per-tool hook.

- **Signal.** Every Codex session rollout (`~/.codex/sessions/**/rollout-*.jsonl`)
  embeds a `token_count` event with `last_token_usage.input_tokens` **and**
  `model_context_window`. So context % is read straight from the session file —
  no plugin needed.
- **Trigger.** A tiny **zero-intrusion background watcher**
  (`codex/codex-context-watcher.sh`) polls the active rollouts. When one crosses
  the threshold **and has gone idle** (Codex writes `token_count` at turn-end, so
  the session is already waiting for input), it generates a handoff and opens a
  fresh `codex` window. Nothing forcibly stops — the old turn is already done.
  It never touches `config.toml` or your `notify` program.
- **Handoff.** The same generator parses the Codex rollout format and captures
  the task, the **`update_plan` steps with their status**, the apply_patch'd
  files, and the git diff — into `.claude/rollover-handoff.md`, just like the
  Claude side.

```bash
./install-codex.sh            # installs the watcher + a launchd agent (auto-starts)
./install-codex.sh --no-daemon  # files only; run the watcher yourself
./uninstall-codex.sh
```

By default it only rolls over **interactive CLI sessions** (`source=cli`).
`codex exec`, subagent, and `vscode`/Codex Desktop sessions live in the same
`~/.codex/sessions/` but are non-interactive or run in another surface, so
opening a fresh CLI window for them would be wrong — they're skipped. Override
with `CODEX_ROLLOVER_SOURCES` (comma-separated, e.g. `cli,vscode`).

Same safety nets as the Claude side (per-session latch, global cooldown, burst
auto-disable, `DISABLED` kill switch), under `~/.codex/rollover-state/`. Knobs are
`CODEX_ROLLOVER_THRESHOLD` / `_POLL` / `_IDLE` / `_COOLDOWN` / `_SOURCES` / `_SEED`.

## Limitations

- macOS-first. On Linux only the **tmux** backend works today (PRs welcome for
  others).
- Depends on claude-hud for the context% signal. If Claude Code later exposes
  usage to hooks directly, this can read it natively.
- Handoff *quality* depends on your repo. With a file-backed handoff
  (repo-harness) the new session resumes precisely; without one it reconstructs
  from git/tasks and is rougher.

## License

MIT — see [LICENSE](LICENSE).
