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
# EVERY command is recorded. There is deliberately no test for "is this a Claude
# launcher" here any more.
#
# There used to be one: the first word was resolved through $aliases/$functions/
# $commands and the result string searched for "claude". That asks the wrong
# question. It is a test on a NAME, so it answers correctly only for launchers
# that happen to spell it — `c` matched because its alias TEXT contains "claude",
# while `ck`, an executable at ~/bin/ck, did not and recorded nothing at all.
# Every wrapper, shell function and `env FOO=1 claude` form fails it the same
# way, and teaching it one more name just moves the goalposts to the next one.
#
# The question that actually matters is not "is this word named claude" but "is
# this pane still running what it launched" — and the SAVE side already knows
# that, from the pane's live process. So the split is:
#
#   here      record the last thing typed, unconditionally, no interpretation
#   pre_save  keep it only for a pane still running something
#
# That is what makes a finished one-shot safe: type `terraform apply`, let it
# finish, and the pane is back at a shell — so the save drops the recording and
# no restore can ever replay it. It also means any launcher works with no
# configuration: ck, cop, a function, a wrapper written next month.
#
# Cost of the change: one small write per interactive command instead of a
# memoized table lookup. No fork — `print -r -- … > file` is a builtin redirect.
_claude_continuity_record() {
  emulate -L zsh
  local line="$1"
  [[ -n "$line" ]] || return 0

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

# ── Clear the recording when the command finishes ────────────────────────────
# preexec records what is about to run; this removes it the moment the shell is
# back at a prompt. The file therefore exists ONLY while a command is actually
# running, which is exactly the set of things a restore should bring back.
#
# That invariant is what makes recording unconditionally safe. Type
# `terraform apply`, let it finish, and the recording is gone before the next
# save can see it — so no restore can replay a completed one-shot. Nothing has to
# guess from a process table, and no program needs to be on an allowlist: if it
# is still running when the snapshot is taken, it comes back; if it finished, it
# does not.
#
# Ordering with _claude_continuity_resume matters. That hook launches claude as a
# CHILD and blocks in `eval`, so this precmd does not run again until claude
# exits — the recording stays in place for the whole life of the session, which
# is the point.
#
# Fork-free, like the rest of the hot path: `rm -f` here would be a fork, so this
# uses zsh's own unlink via the `zsh/files` module when available and falls back
# to a builtin-only truncate otherwise.
zmodload -F zsh/files b:zf_rm 2>/dev/null
if (( $+builtins[zf_rm] )); then
  _claude_continuity_clear() { zf_rm -f -- "$_CC_LAUNCH_FILE" 2>/dev/null }
else
  # No zsh/files: emptying the file is the fork-free equivalent. pre_save treats
  # an empty recording as absent.
  _claude_continuity_clear() { : > "$_CC_LAUNCH_FILE" 2>/dev/null }
fi

autoload -Uz add-zsh-hook
add-zsh-hook precmd _claude_continuity_resume
add-zsh-hook precmd _claude_continuity_clear
add-zsh-hook preexec _claude_continuity_preexec
