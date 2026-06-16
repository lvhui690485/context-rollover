# claude-context-rollover

**When a Claude Code session fills up its context window, hand the work off to a
fresh window — automatically.**

At a configurable threshold (default **60%** of the context window), this hook:

1. opens a **new, lean `claude` session** in a split pane / new window, in the
   same repo, seeded with a prompt to continue from where you left off, and
2. **stops the current session** cleanly, so you don't keep grinding with a
   nearly-full window (slower, dumber, more expensive).

You keep working in the new window. The baton is passed. No manual `/compact`, no
copy-pasting context, no babysitting.

> Works best with a **file-backed handoff** in your repo (e.g.
> [repo-harness](https://github.com/Ancienttwo/repo-harness)'s `resume.md`,
> injected on `SessionStart`). Without one it falls back to telling the new
> session to reconstruct state from `git log/status` and any task files.

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
git clone https://github.com/<you>/claude-context-rollover
cd claude-context-rollover
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
