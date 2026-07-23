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

# Resolve both directories in ONE tmux call at source time. TMUX_PANE is stable
# across `exec` and for the life of the pane, so this never needs recomputing.
# `#{@option}` reads a user option inside a format, which lets a single
# display-message return both values instead of one show-option call each.
_CC_DIRS="$(tmux display-message -p '#{@claude-continuity-pending-dir}|#{@claude-continuity-launch-dir}' 2>/dev/null)"
_CC_PENDING_DIR="${_CC_DIRS%%|*}"
_CC_LAUNCH_DIR="${_CC_DIRS##*|}"
_CC_PENDING_DIR="${_CC_PENDING_DIR:-$HOME/.config/tmux-claude/pending}"
_CC_LAUNCH_DIR="${_CC_LAUNCH_DIR:-$HOME/.config/tmux-claude/launch}"
_CC_PENDING_FILE="${_CC_PENDING_DIR}/${TMUX_PANE#%}"
_CC_LAUNCH_FILE="${_CC_LAUNCH_DIR}/${TMUX_PANE#%}"

# ── Record the launch command, exactly as typed ──────────────────────────────
# `ps` cannot answer "what did the user actually run". By the time a process
# exists the shell has already expanded the alias — `c` is gone, replaced by
# `op run … -- claude --dangerously-skip-permissions` — and argv has been
# flattened to a single space-joined string, so `--name "My Session"` is
# indistinguishable from two separate arguments. Rebuilding a launch command
# from that is guesswork.
#
# zsh hands us the real thing: preexec's $1 is the line as TYPED, before alias
# expansion and with quoting intact. Verified on zsh 5.9 in a pty:
#     typed: c --worktree qr --name "My Session"
#     $1   = c --worktree qr --name "My Session"
#     $3   = true --worktree qr --name "My Session"      (alias expanded)
# Recording $1 means a restored pane can run the identical command, alias and
# all, with no reconstruction. post_restore falls back to the ps-derived command
# when this file is absent — panes launched from a script, from `tmux new-window
# 'claude …'`, or from a shell without this hook never pass through preexec.
#
# This runs on EVERY interactive command, so it must not fork. Command
# resolution uses zsh's own tables ($aliases/$functions/$commands) rather than
# `whence` in a $( ) subshell, and the verdict per command word is memoized.
typeset -gA _cc_launcher_memo

_claude_continuity_record() {
  emulate -L zsh
  local line="$1"
  [[ -n "$line" ]] || return 0

  local word="${line%%[[:space:]]*}"
  [[ -n "$word" ]] || return 0

  local verdict="${_cc_launcher_memo[$word]-}"
  if [[ -z "$verdict" ]]; then
    # What would this word actually run? Alias text, function name, or binary.
    local resolved="${aliases[$word]-}${functions[$word]:+$word}${commands[$word]-}"
    case " $resolved " in
      *' claude '*|*'/claude '*|*'/claude'|*' claudish '*|*'/claudish '*|*'/claudish'|*'claudish '*)
        verdict=y ;;
      *) verdict=n ;;
    esac
    case "$word" in claude|claudish) verdict=y ;; esac
    _cc_launcher_memo[$word]="$verdict"
  fi
  [[ "$verdict" = y ]] || return 0

  [[ -d "$_CC_LAUNCH_DIR" ]] || mkdir -p "$_CC_LAUNCH_DIR" 2>/dev/null || return 0
  # First line only: the snapshot is a line-oriented format, and a continuation
  # would corrupt the row it is embedded in.
  print -r -- "${line%%$'\n'*}" > "$_CC_LAUNCH_FILE" 2>/dev/null
}

_claude_continuity_preexec() { _claude_continuity_record "$1" }

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

  # Record what we are about to run as this pane's launch command. preexec does
  # NOT fire for this — it is an eval inside a hook, not a line the user typed —
  # so without this the pane would have no recorded command until the user next
  # launches Claude by hand, and the next save would fall back to ps.
  _claude_continuity_record "$cmd"

  # Run claude as a CHILD of the shell — do NOT exec.
  #
  # exec would replace this zsh with claude, so quitting claude would leave the
  # pane with no program and tmux would close it. That breaks the parity we
  # actually want: a normal `claude` is typed at an interactive prompt, so
  # quitting it drops you back to THAT shell. On a restored pane the precmd-
  # launched claude is the pane's only program, so to preserve the same "quit →
  # interactive zsh" behavior we must keep the shell alive underneath.
  #
  # eval handles the flags/args embedded in the saved command string. After
  # claude exits we return to the normal interactive prompt; the hook has already
  # disarmed itself above, so there is no relaunch loop.
  eval "${cmd}"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _claude_continuity_resume
add-zsh-hook preexec _claude_continuity_preexec
