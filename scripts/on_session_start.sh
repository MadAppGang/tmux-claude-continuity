#!/usr/bin/env bash
# on_session_start.sh — Claude Code SessionStart hook
#
# Fires once when a Claude Code session starts or resumes. Writes the
# session_id to a per-pane sidecar file keyed by stable tmux pane identity
# (session-window-pane index), which survives tmux-resurrect restore.
#
# Add to ~/.claude/settings.json:
#
#   "hooks": {
#     "SessionStart": [
#       {
#         "hooks": [
#           {
#             "type": "command",
#             "command": "bash ~/.tmux/plugins/tmux-claude-continuity/scripts/on_session_start.sh"
#           }
#         ]
#       }
#     ]
#   }
#
# Input JSON fields (from Claude Code):
#   session_id      — UUID of the session
#   source          — "startup" | "resume" | "clear" | "compact"
#   cwd             — current working directory
#   transcript_path — path to the .jsonl file
#   model           — model identifier

input="$(cat)"

session_id="$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)"

[ -n "$session_id" ] || exit 0

pane_key="$(tmux display-message -p '#S-#I-#P' 2>/dev/null)"

[ -n "$pane_key" ] || exit 0

panes_dir="$(tmux show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"

mkdir -p "$panes_dir"
echo "$session_id" > "${panes_dir}/${pane_key}.session-id"
