#!/usr/bin/env bash
# on_session_start.sh — Claude Code SessionStart hook
#
# Fires once when a Claude Code session starts or resumes. Writes the
# session_id to a per-pane sidecar file keyed by stable tmux pane identity
# (session-window-pane index), which survives tmux-resurrect restore.
#
# Skips subagent sessions (e.g. claudish-spawned instances) by detecting:
#   1. agent_type field in the SessionStart JSON (set when --agent flag is used)
#   2. CLAUDISH_ACTIVE_MODEL_NAME env var (always set by claudish to the active model name)
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

input="$(cat)"

# ── Skip subagent sessions ────────────────────────────────────────────────────

# Signal 1: agent_type is set → spawned with --agent flag (claudish, subagents)
agent_type="$(echo "$input" | jq -r '.agent_type // empty' 2>/dev/null)"
[ -n "$agent_type" ] && exit 0

# Signal 2: CLAUDISH_ACTIVE_MODEL_NAME is set → running inside claudish proxy
[ -n "$CLAUDISH_ACTIVE_MODEL_NAME" ] && exit 0

# ── Capture session ID ────────────────────────────────────────────────────────

session_id="$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$session_id" ] || exit 0

pane_key="$(tmux display-message -p '#S-#I-#P' 2>/dev/null)"
[ -n "$pane_key" ] || exit 0

panes_dir="$(tmux show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"

mkdir -p "$panes_dir"
echo "$session_id" > "${panes_dir}/${pane_key}.session-id"
