#!/usr/bin/env bash
# post_restore.sh — tmux-resurrect post-restore hook
#
# Triggered by: @resurrect-hook-post-restore-all (restore.sh:382, undocumented)
# Fires after all panes, processes, zoom states, and sessions are restored.
#
# For each pane that was running claude, resolves the live tmux pane id and
# drops a "pending resume" file keyed by that pane id. The companion
# claude-continuity.zsh precmd hook reads it on the shell's first prompt and
# execs the command.
#
# Why not send-keys? A freshly restored shell is still sourcing .zshrc when this
# hook runs; keystrokes sent into it are dropped (typeahead flushed by
# starship/zsh-autosuggestions redraw). The old fixed `restore-delay` sleep was
# a race against shell init, not a fix. The pending-file + first-prompt precmd
# approach is timing-free: the shell relaunches claude itself once it is ready.

TMUX_CMD="${TMUX_CMD:-tmux}"

# Resolve the snapshot path the SAME way tmux-resurrect does, so we always read
# the file that was actually restored. An explicit RESURRECT_FILE env wins (used
# by tests); otherwise honor @resurrect-dir (resurrect's own option), expanding
# $HOME/tilde as resurrect's helpers.sh does, and fall back to its default dir.
if [ -z "${RESURRECT_FILE:-}" ]; then
  _rd="$($TMUX_CMD show-option -gqv @resurrect-dir 2>/dev/null)"
  if [ -z "$_rd" ]; then
    _rd="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
  else
    # expand a leading ~ and any $HOME, matching resurrect's expansion
    _rd="${_rd/#\~/$HOME}"
    _rd="$(eval "printf '%s' \"$_rd\"")"
  fi
  RESURRECT_FILE="$_rd/last"
fi

panes_dir="$($TMUX_CMD show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"

pending_dir="$($TMUX_CMD show-option -gqv @claude-continuity-pending-dir 2>/dev/null)"
pending_dir="${pending_dir:-$HOME/.config/tmux-claude/pending}"

claude_cmd="$($TMUX_CMD show-option -gqv @claude-continuity-claude-cmd 2>/dev/null)"
claude_cmd="${claude_cmd:-claude}"

# Relaunch via the resolved claude binary rather than a shell alias when the
# configured command is the bare `c`/alias form.
#
# The pending command is run by the precmd as `eval "exec <cmd> ..."`. zsh does
# NOT expand aliases on the word after the `exec` keyword, so a bare alias like
# `c` fails with "command not found". We must therefore resolve the configured
# command to a concrete program string at write time:
#   1. If it contains a space, it's already a full command — keep verbatim.
#   2. Else if it's a real binary on PATH — use its absolute path.
#   3. Else try expanding it as an interactive-shell alias (the common case:
#      @claude-continuity-claude-cmd = "c", an alias for "claude --flags").
#   4. Else fall back to the word as-is.
resolve_claude_cmd() {
  case "$claude_cmd" in
    *' '*) printf '%s' "$claude_cmd"; return ;;   # already a full command
  esac

  local bin
  bin="$(command -v "$claude_cmd" 2>/dev/null)"
  if [ -n "$bin" ] && [ "$bin" != "$claude_cmd" ]; then
    # command -v returned a path/builtin, not just echoing an alias name back
    case "$bin" in
      /*) printf '%s' "$bin"; return ;;
    esac
  fi

  # Expand as an interactive zsh alias. `whence -c <name>` in an interactive
  # shell prints the alias expansion (e.g. "c: aliased to claude --flags" →
  # we want the RHS). Use `alias <name>` parsing which is stable across zsh.
  local expanded
  expanded="$(zsh -ic "alias ${claude_cmd}" 2>/dev/null | head -1)"
  # Format: c='claude --dangerously-skip-permissions'
  case "$expanded" in
    "${claude_cmd}="*)
      expanded="${expanded#*=}"
      # strip surrounding single quotes if present
      expanded="${expanded#\'}"; expanded="${expanded%\'}"
      if [ -n "$expanded" ]; then printf '%s' "$expanded"; return; fi
      ;;
  esac

  # Last resort: emit the word as-is (works if it happens to be a real binary
  # the interactive shell can find).
  printf '%s' "$claude_cmd"
}

[ -f "$RESURRECT_FILE" ] || exit 0

mkdir -p "$pending_dir"

# Build set of all pane keys present in the resurrect file (bash 3.2 compatible)
known_panes=""
while IFS=$'\t' read -r line_type session win win_active win_flags pane_idx _rest; do
  [ "$line_type" = "pane" ] || continue
  known_panes="${known_panes}|${session}-${win}-${pane_idx}"
done < "$RESURRECT_FILE"

# Remove sidecar files for panes that no longer exist
for sidecar in "${panes_dir}"/*.session-id; do
  [ -f "$sidecar" ] || continue
  key="$(basename "$sidecar" .session-id)"
  case "$known_panes" in
    *"|${key}"*) ;;  # key exists in set
    *) rm -f "$sidecar" ;;
  esac
done

base_cmd="$(resolve_claude_cmd)"

# Queue a pending resume for each pane that was running claude.
while IFS=$'\t' read -r line_type session win win_active win_flags pane_idx \
        pane_title dir pane_active pane_cmd pane_full_cmd extra1 extra2; do
  [ "$line_type" = "pane" ] || continue

  # Strip leading ":" sentinel from full command field
  full_cmd="${pane_full_cmd#:}"

  # Only act on panes that were running claude (or custom alias)
  [[ "$full_cmd" == *"claude"* ]] || [[ "$full_cmd" == *"$claude_cmd"* ]] || continue

  # Prefer the snapshot-embedded session ID (written by pre_save.sh at save
  # time). Format: ";CLAUDE_SID=<uuid>" appearing as a trailing field.
  resume_token=""
  for field in "$extra1" "$extra2"; do
    case "$field" in
      ";CLAUDE_SID="*) resume_token="${field#;CLAUDE_SID=}"; break ;;
    esac
  done

  # Fall back to position-keyed sidecar if snapshot wasn't enriched.
  if [ -z "$resume_token" ]; then
    pane_key="${session}-${win}-${pane_idx}"
    metadata_file="${panes_dir}/${pane_key}.session-id"
    if [ -f "$metadata_file" ]; then
      resume_token="$(head -1 "$metadata_file")"
    fi
  fi

  # Resolve the live tmux pane id (%N) for this snapshot position. The precmd
  # hook keys off $TMUX_PANE, so we must write the pending file under the pane
  # id, not the session:window.pane string.
  pane_target="${session}:${win}.${pane_idx}"
  pane_id="$($TMUX_CMD display-message -t "$pane_target" -p '#{pane_id}' 2>/dev/null)"
  if [ -z "$pane_id" ]; then
    # Pane no longer exists in the live layout (e.g. a session was killed
    # between save and restore). Nothing to relaunch into; skip quietly.
    continue
  fi
  pane_key_file="${pending_dir}/${pane_id#%}"

  if [ -n "$resume_token" ]; then
    printf '%s --resume %s\n' "$base_cmd" "$resume_token" > "$pane_key_file"
  else
    printf '%s\n' "$base_cmd" > "$pane_key_file"
  fi

  # Nudge the pane so the armed precmd hook fires now. Two orderings to cover:
  #   - shell still sourcing .zshrc: the file is already written, so its first
  #     prompt consumes it; this Enter lands on a not-yet-ready shell and is
  #     harmless (an empty line at a prompt is a no-op).
  #   - shell already idle at a prompt (it reached first-prompt before we wrote
  #     the file, so precmd ran once and found nothing — but it stayed armed):
  #     this Enter triggers a fresh prompt cycle, and the now-present file fires.
  # We send a bare Enter (not the command) — the resume is driven entirely by the
  # precmd reading the pending file, never by keystrokes that a busy shell drops.
  $TMUX_CMD send-keys -t "$pane_id" "" Enter 2>/dev/null

done < "$RESURRECT_FILE"
