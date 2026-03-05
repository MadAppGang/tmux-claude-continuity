# tmux-claude-continuity

Automatically resume Claude Code sessions after [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) restore.

## Quick start

**Step 1.** Install the plugin (TPM):

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'MadAppGang/tmux-claude-continuity'
```

Press `prefix + I` to install.

**Step 2.** Register the hooks in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_session_start.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_stop.sh"
          }
        ]
      }
    ]
  }
}
```

Done. Next time tmux-resurrect restores your sessions, Claude Code resumes where you left off.

---

## The problem

You run Claude Code in a tmux pane. You save your tmux session with tmux-resurrect, then restore it — maybe after a reboot or a `tmux kill-server`. tmux-resurrect recreates your pane layout and reruns the shell command. But Claude Code starts a brand-new session, not the one you were in. Your conversation context is gone.

You can recover manually with `claude --resume <uuid>`, but first you have to find the right UUID — and if you had Claude running in several panes, you have to match each UUID to the correct pane.

## The solution

tmux-claude-continuity does that bookkeeping for you.

Every time Claude Code starts a session (new, resumed, cleared, or compacted), its `SessionStart` hook writes a resume token to a file named after the pane's position: `~/.config/tmux-claude/panes/<session>-<window>-<pane>.session-id`.

If you named your session with `/title`, the token is that name. Otherwise it is the session UUID. The `Stop` hook keeps the token updated after every turn, so `/title` changes take effect immediately.

After tmux-resurrect restores, a post-restore hook reads those files and sends `claude --resume <token>` to each pane that was running Claude.

## How it works

```
Claude Code starts in pane  work:1.0
  └── SessionStart hook fires
      └── writes  ~/.config/tmux-claude/panes/work-1-0.session-id
                  (contains session UUID, or custom title if /title was used)

User types /title bugfix-sentry
  └── Stop hook fires after the turn
      └── updates  work-1-0.session-id  →  "bugfix-sentry"

You restore tmux with tmux-resurrect
  └── post_restore.sh fires after all panes are recreated
      ├── reads the resurrect save file
      ├── finds panes that were running claude
      └── sends  claude --resume bugfix-sentry  (or --resume <uuid>)  to each one
```

### Why pane identity survives restore

Each pane is keyed by `session_name-window_index-pane_index` (e.g. `work-1-0`). tmux-resurrect recreates panes at exactly these positions, so the key written before a save matches the pane address after restore. The ephemeral `%N` numeric pane ID — which changes every session — is never used.

---

## Requirements

- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- [jq](https://jqlang.github.io/jq/)
- Claude Code >= 2.0

**Optional:** [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) for automatic periodic saves.

---

## Installation

### TPM (recommended)

Add to `~/.tmux.conf` in this order — tmux-resurrect must load before this plugin:

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'  # optional
set -g @plugin 'MadAppGang/tmux-claude-continuity'
```

Press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/MadAppGang/tmux-claude-continuity \
  ~/.tmux/plugins/tmux-claude-continuity
```

Add to `~/.tmux.conf` after the tmux-resurrect line:

```tmux
run-shell ~/.tmux/plugins/tmux-claude-continuity/tmux-claude-continuity.tmux
```

---

## Configuration

### Claude Code hooks (required)

The hooks go in `~/.claude/settings.json`, not `~/.tmux.conf`. This is the step most users miss.

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_session_start.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_stop.sh"
          }
        ]
      }
    ]
  }
}
```

`SessionStart` captures the session on startup. `Stop` keeps the resume token updated after every turn — required for `/title` changes to take effect without restarting.

If you already have a `hooks` key in `settings.json`, add `SessionStart` and `Stop` alongside your existing hooks.

### tmux.conf options (all optional)

```tmux
# Where per-pane session ID files are stored
# Default: ~/.config/tmux-claude/panes
set -g @claude-continuity-panes-dir "$HOME/.config/tmux-claude/panes"

# Seconds to wait after restore before sending keys
# Increase if your shell init is slow
# Default: 1
set -g @claude-continuity-restore-delay "1"

# Flags appended to every restored claude command
# Default: --dangerously-skip-permissions
set -g @claude-continuity-claude-flags "--dangerously-skip-permissions"

# Command used to launch Claude Code
# Use this if you have a shell alias (e.g. 'c' for claude in yolo mode)
# Default: claude
set -g @claude-continuity-claude-cmd "claude"
```

---

## Troubleshooting

### Sessions not resuming after restore

Check whether the sidecar files exist:

```bash
ls ~/.config/tmux-claude/panes/
# Expected: work-1-0.session-id  work-2-0.session-id  ...
```

Files appear after Claude Code's first API response in each pane (that is when `SessionStart` fires). An empty directory means the hook is not running. Verify `~/.claude/settings.json` contains the `SessionStart` entry shown above, then restart Claude Code.

### Restore starts a fresh session instead of resuming

This happens when no sidecar file exists for a pane — for example, a pane that never ran Claude before or a new pane added after the last save. The plugin falls back to `claude <flags>`, starting a fresh session.

### Wrong session resumed

The sidecar file updates on every `SessionStart` event (startup, resume, clear, compact), so it always reflects the most recent session in that pane. If you see a wrong session resumed, the save was taken before a session switch; save again with `prefix + C-s` to capture the current state.

### Restore delay too short

If Claude starts before your shell finishes sourcing rc files, increase the delay:

```tmux
set -g @claude-continuity-restore-delay "3"
```

---

## License

MIT — [MadAppGang](https://github.com/MadAppGang/tmux-claude-continuity)
