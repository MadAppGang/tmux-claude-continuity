#!/usr/bin/env bash
# on_stop.sh — Claude Code Stop hook
#
# Fires after every completed Claude turn. Updates the custom title in the
# per-pane sidecar file so that /rename changes are captured without needing
# to restart the session.
#
# Add to ~/.claude/settings.json alongside the SessionStart hook:
#
#   "Stop": [
#     {
#       "hooks": [
#         {
#           "type": "command",
#           "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_stop.sh"
#         }
#       ]
#     }
#   ]

input="$(cat)"

# Skip claudish-spawned sessions
[ -n "$CLAUDISH_ACTIVE_MODEL_NAME" ] && exit 0

session_id="$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$session_id" ] || exit 0

cwd="$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$cwd" ] || exit 0

pane_key="$(tmux display-message -p '#S-#I-#P' 2>/dev/null)"
[ -n "$pane_key" ] || exit 0

panes_dir="$(tmux show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"

metadata_file="${panes_dir}/${pane_key}.session-id"
[ -f "$metadata_file" ] || exit 0

# Read customTitle from session JSONL
project_key="$(echo "$cwd" | sed 's|/|-|g')"
jsonl="$HOME/.claude/projects/${project_key}/${session_id}.jsonl"
[ -f "$jsonl" ] || exit 0

custom_title="$(grep '"custom-title"' "$jsonl" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)"

# Write title if set, UUID otherwise
if [ -n "$custom_title" ]; then
  echo "$custom_title" > "$metadata_file"
else
  echo "$session_id" > "$metadata_file"
fi
