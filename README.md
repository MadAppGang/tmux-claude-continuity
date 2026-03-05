# tmux-claude-continuity

Automatically resume Claude Code sessions after [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) restore.

When tmux-resurrect restores your sessions, Claude Code instances are killed and you lose track of which session was running in which pane. This plugin solves that by capturing each pane's Claude Code session ID at startup and resuming the correct session automatically after restore.

## How it works

1. **Capture** — Claude Code's `SessionStart` hook fires when a session starts. The plugin writes the session UUID to a per-pane file keyed by stable pane identity (`session-window-pane`).
2. **Restore** — After tmux-resurrect restores all panes, a post-restore hook reads each pane's saved UUID and runs `claude --resume <uuid>` in the correct pane.

```
claude starts in pane circl:1.0
  → SessionStart hook fires
  → writes ~/.config/tmux-claude/panes/circl-1-0.session-id

tmux-resurrect restores
  → post_restore.sh reads save file
  → sends "claude --resume <uuid>" to each claude pane
```

## Requirements

- [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect)
- [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) (optional, for automatic saves)
- [jq](https://jqlang.github.io/jq/)
- Claude Code >= 2.0

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'MadAppGang/tmux-claude-continuity'
```

Then press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/MadAppGang/tmux-claude-continuity ~/.tmux/plugins/tmux-claude-continuity
```

Add to `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-claude-continuity/tmux-claude-continuity.tmux
```

## Configuration

### 1. Register the SessionStart hook in Claude Code

Add to `~/.claude/settings.json`:

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
    ]
  }
}
```

### 2. tmux.conf options

All options are optional — defaults work out of the box.

```tmux
# Directory where per-pane session ID files are stored
# Default: ~/.config/tmux-claude/panes
set -g @claude-continuity-panes-dir "$HOME/.config/tmux-claude/panes"

# Seconds to wait after restore before sending keys (let shells finish init)
# Default: 1
set -g @claude-continuity-restore-delay "1"

# Flags appended to the restored claude command
# Default: --dangerously-skip-permissions
set -g @claude-continuity-claude-flags "--dangerously-skip-permissions"
```

### 3. Ensure tmux-resurrect is loaded before this plugin

```tmux
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'MadAppGang/tmux-claude-continuity'
```

## How pane identity works

Panes are identified by `session_name-window_index-pane_index` (e.g. `work-1-0`). This triple is stable across tmux-resurrect restore — resurrect explicitly recreates panes at the same positions. The ephemeral `%N` numeric pane ID is not used.

## Troubleshooting

**Sessions not resuming after restore**

Check that sidecar files are being written:
```bash
ls ~/.config/tmux-claude/panes/
```
Files should appear after Claude Code's first API response in each pane. If the directory is empty, verify the `SessionStart` hook is configured in `~/.claude/settings.json`.

**Wrong session resumed**

The sidecar file is updated on every `SessionStart` event (startup, resume, clear, compact), so it always reflects the most recent session in each pane.

**Fresh session started instead of resume**

If no sidecar file exists for a pane (e.g. the pane never ran Claude Code before), the plugin falls back to starting a fresh `claude` session.

## License

MIT
