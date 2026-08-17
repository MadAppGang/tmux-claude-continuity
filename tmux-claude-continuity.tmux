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
#   @claude-continuity-claude-cmd    Command used to (re)launch claude, used
#                                    EXACTLY as written — an alias ("c"), a shell
#                                    function, a binary, or a full command line.
#                                    The precmd evals it, so aliases and functions
#                                    resolve normally. Default: claude
#
# Window freeze / thaw ("sleep") — prefix + Z opens the sleep manager:
#   @claude-continuity-freeze-dir    Root of the frozen-window store. NO PATH
#                                    COMPONENT MAY CONTAIN "claude": these paths
#                                    appear in a tombstone pane's argv, and the
#                                    restore path skips any command containing
#                                    "claude", which is what stops an older
#                                    plugin from re-arming a tombstone.
#                                    Default: ~/.config/tmux-cc/frozen
#   @claude-continuity-autofreeze    Master switch for the automatic sweep.
#                                    Off means the sweep freezes NOTHING,
#                                    whatever the idle ages. Default: off
#   @claude-continuity-autofreeze-idle
#                                    Idle threshold for the sweep and for the
#                                    popup's "idle" counter. Accepts 2d, 36h,
#                                    90m, 45s or bare seconds. Default: 2d
#   @cc-frozen                       WINDOW-LOCAL, set by the plugin, never by
#                                    you: the key of the store entry this window
#                                    currently claims. A claim token, not an
#                                    authority — the state file is the record.
#
# Resume is driven by a zsh precmd hook (claude-continuity.zsh), NOT by timed
# send-keys. Source it from ~/.zshrc:
#   source ~/.tmux/plugins/tmux-claude-continuity/claude-continuity.zsh
# The old @claude-continuity-restore-delay option is obsolete (the precmd fires
# on the shell's first real prompt, so there is no delay to tune).

CURRENT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Register the pre-restore hook for tmux-resurrect. It purges stale pending
# resumes before any pane exists — the only point at which that is still safe.
# Note: @resurrect-hook-pre-restore-all is undocumented but confirmed in restore.sh:369
tmux set-option -g @resurrect-hook-pre-restore-all \
  "${CURRENT_DIR}/scripts/pre_restore.sh"

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

# The AFTER-PUBLICATION check. post-save-layout above runs at save.sh:246, which
# is BEFORE the `files_differ` / `ln -fs … last` at :247-251 — so whether `last`
# ends up dangling is decided after that hook has already returned, and no amount
# of work inside it can guarantee the outcome. resurrect calls post-save-all at
# save.sh:259, after the symlink has been moved, which is the only point where
# the result can actually be checked.
#
# Measured against the real save.sh with ten concurrent saves: vanilla resurrect
# leaves `last` unrestorable 3 runs in 3; the :246 guards alone cut that to 1 in
# 3 (reproduced here as a 1-in-3 flake in tests/save_lock_mutex.sh, where `last`
# simply vanished); with this hook wired it is 0. `--verify-last` was written for
# exactly this and was already implemented in pre_save.sh — it had just never
# been registered, so the last third of the failure was never being caught.
tmux set-option -g @resurrect-hook-post-save-all \
  "${CURRENT_DIR}/scripts/pre_save.sh --verify-last"

# The sleep manager. prefix + Z — Z is unbound in default tmux (prefix + z is
# zoom; the key table is case-sensitive), so this takes nothing away.
#
# NO NEW RESURRECT HOOK IS REGISTERED HERE and no existing hook option changes
# value: a cold boot can run this file after resurrect has already read its hook
# options, so a new registration would be a race, not a feature.
#
# display-popup arrived in tmux 3.2. On anything older the manager opens in a
# scratch window instead, which behaves identically — it is a full-screen fzf
# either way.
if tmux list-commands 2>/dev/null | grep -q '^display-popup'; then
  tmux bind-key Z display-popup -E -w 90% -h 85% \
    "${CURRENT_DIR}/scripts/cc_popup.sh"
else
  tmux bind-key Z new-window -n "sleep-manager" \
    "${CURRENT_DIR}/scripts/cc_popup.sh"
fi
