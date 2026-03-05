#!/usr/bin/env bash
# tmux-claude-continuity
# Automatically resume Claude Code sessions after tmux-resurrect restore.
#
# Uses Claude Code's SessionStart hook to capture session IDs per pane,
# then resumes them via @resurrect-hook-post-restore-all after restore.
#
# Options (set in ~/.tmux.conf):
#   @claude-continuity-panes-dir     Where to store per-pane session ID files
#                                    Default: ~/.config/tmux-claude/panes
#   @claude-continuity-restore-delay Seconds to wait before sending keys on restore
#                                    Default: 1
#   @claude-continuity-claude-flags  Extra flags appended to restored claude command
#                                    Default: --dangerously-skip-permissions

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Register the post-restore hook for tmux-resurrect
# Note: @resurrect-hook-post-restore-all is undocumented but confirmed in restore.sh:382
tmux set-option -g @resurrect-hook-post-restore-all \
  "${CURRENT_DIR}/scripts/post_restore.sh"
