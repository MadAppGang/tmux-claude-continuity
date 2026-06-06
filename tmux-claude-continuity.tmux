#!/usr/bin/env bash
# tmux-claude-continuity
# Automatically resume Claude Code sessions after tmux-resurrect restore.
#
# Uses Claude Code's SessionStart hook to capture session IDs per pane,
# then resumes them via @resurrect-hook-post-restore-all after restore.
#
# Options (set in ~/.tmux.conf):
#   @claude-continuity-panes-dir     Where to store per-pane session ID sidecars
#                                    Default: ~/.config/tmux-claude/panes
#   @claude-continuity-pending-dir   Where post_restore queues pending resumes for
#                                    the claude-continuity.zsh precmd hook to read
#                                    Default: ~/.config/tmux-claude/pending
#   @claude-continuity-claude-cmd    Command used to (re)launch claude. A bare
#                                    alias like "c" is expanded to its binary form
#                                    at restore time. Default: claude
#
# Resume is driven by a zsh precmd hook (claude-continuity.zsh), NOT by timed
# send-keys. Source it from ~/.zshrc:
#   source ~/.tmux/plugins/tmux-claude-continuity/claude-continuity.zsh
# The old @claude-continuity-restore-delay option is obsolete (the precmd fires
# on the shell's first real prompt, so there is no delay to tune).

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Register the post-restore hook for tmux-resurrect
# Note: @resurrect-hook-post-restore-all is undocumented but confirmed in restore.sh:382
tmux set-option -g @resurrect-hook-post-restore-all \
  "${CURRENT_DIR}/scripts/post_restore.sh"

# Register the post-save-layout hook to enrich the snapshot with session IDs.
# Resurrect calls this hook with the snapshot file path as $1 right after
# writing it. Embedding the ID at save time makes the snapshot immune to
# position drift (window renumber/move/swap between save and restore).
tmux set-option -g @resurrect-hook-post-save-layout \
  "${CURRENT_DIR}/scripts/pre_save.sh \"\$1\""
