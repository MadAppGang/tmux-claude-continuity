# claude-continuity.zsh — first-prompt resume for restored tmux panes
#
# Source this from ~/.zshrc:
#   source ~/.tmux/plugins/tmux-claude-continuity/claude-continuity.zsh
#
# Why a precmd hook instead of tmux send-keys?
# post_restore.sh used to `send-keys "c --resume <token>" Enter` into each
# restored pane ~1s after restore. On a freshly spawned shell that is still
# sourcing a heavy .zshrc, those keystrokes are dropped (typeahead flushed by
# starship / zsh-autosuggestions redraw), so claude never launches and the pane
# sits at a bare prompt. A fixed delay can't fix this — it's a race with shell
# init, not a constant.
#
# Instead, post_restore.sh writes a per-pane "pending resume" file. This hook
# fires on the shell's FIRST prompt — i.e. AFTER .zshrc has fully sourced and
# the shell is genuinely interactive — reads its own pending file, execs the
# command, and disarms itself. No send-keys, no timing guess, no dropped keys.
#
# Stays armed until it actually consumes a file, because on a real restore the
# shell can reach its first prompt BEFORE post_restore.sh writes the pending file
# (post_restore runs in the post-restore-all hook, after every pane exists). It
# must therefore re-check on later prompts — but the per-prompt check is a bare
# file stat with NO subprocess, so an ordinary shell that never gets a file pays
# only a single string test per prompt. The pending path is resolved ONCE here at
# source time (one `tmux` fork total), not on every prompt.
#
# One-shot on consume: after firing once it removes itself from precmd, so
# quitting the resumed claude drops you to a normal shell (no relaunch loop).

# Only meaningful inside tmux, and only for interactive shells.
[[ -n "$TMUX_PANE" ]] || return 0
[[ -o interactive ]] || return 0

# Resolve the pending-file path exactly once, at source time. TMUX_PANE is stable
# across `exec` and for the life of the pane, so this never needs recomputing.
_CC_PENDING_DIR="$(tmux show-option -gqv @claude-continuity-pending-dir 2>/dev/null)"
_CC_PENDING_DIR="${_CC_PENDING_DIR:-$HOME/.config/tmux-claude/pending}"
_CC_PENDING_FILE="${_CC_PENDING_DIR}/${TMUX_PANE#%}"

_claude_continuity_resume() {
  # Fork-free hot path: a single file stat per prompt. No file yet → stay armed
  # (the file may be written later by post_restore) and return cheaply.
  [[ -f "$_CC_PENDING_FILE" ]] || return 0

  # We have a file: this is our one shot. Disarm now so we never fire twice, and
  # so quitting the resumed claude drops to a normal shell (no relaunch loop).
  add-zsh-hook -d precmd _claude_continuity_resume 2>/dev/null
  unfunction _claude_continuity_resume 2>/dev/null

  local cmd
  cmd="$(<"$_CC_PENDING_FILE")"
  rm -f "$_CC_PENDING_FILE"

  [[ -n "$cmd" ]] || return 0

  # exec so claude replaces the shell — quitting claude ends the pane's program
  # exactly like a normal `claude` invocation would. eval handles the flags/args
  # embedded in the saved command string.
  eval "exec ${cmd}"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _claude_continuity_resume
