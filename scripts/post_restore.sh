#!/usr/bin/env bash
# post_restore.sh — tmux-resurrect post-restore hook
#
# Triggered by: @resurrect-hook-post-restore-all (restore.sh:382, undocumented)
# Fires after all panes, processes, zoom states, and sessions are restored.
#
# For each pane that was running claude, reads the saved resume token from the
# per-pane sidecar file and sends `<claude_cmd> --resume <token>` to that pane.

TMUX_CMD="${TMUX_CMD:-tmux}"
RESURRECT_FILE="${RESURRECT_FILE:-$HOME/.local/share/tmux/resurrect/last}"

panes_dir="$($TMUX_CMD show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"

restore_delay="$($TMUX_CMD show-option -gqv @claude-continuity-restore-delay 2>/dev/null)"
restore_delay="${restore_delay:-1}"

claude_cmd="$($TMUX_CMD show-option -gqv @claude-continuity-claude-cmd 2>/dev/null)"
claude_cmd="${claude_cmd:-claude}"

if [ ! -f "$RESURRECT_FILE" ]; then
  exit 0
fi

# Give shells time to finish sourcing rc files after restore
sleep "$restore_delay"

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

# Resume claude in panes that were running it
while IFS=$'\t' read -r line_type session win win_active win_flags pane_idx \
        pane_title dir pane_active pane_cmd pane_full_cmd; do
  [ "$line_type" = "pane" ] || continue

  # Strip leading ":" sentinel from full command field
  full_cmd="${pane_full_cmd#:}"

  # Only act on panes that were running claude (or custom alias)
  [[ "$full_cmd" == *"claude"* ]] || [[ "$full_cmd" == *"$claude_cmd"* ]] || continue

  pane_key="${session}-${win}-${pane_idx}"
  metadata_file="${panes_dir}/${pane_key}.session-id"

  if [ ! -f "$metadata_file" ]; then
    $TMUX_CMD send-keys -t "${session}:${win}.${pane_idx}" "$claude_cmd" "Enter"
    continue
  fi

  # Line 1 is always the UUID; line 2 (if present) is the display title.
  # Old single-line sidecars may contain a title instead of UUID — still usable
  # as a --resume search term, but less reliable.
  resume_token="$(head -1 "$metadata_file")"

  if [ -n "$resume_token" ]; then
    $TMUX_CMD send-keys -t "${session}:${win}.${pane_idx}" \
      "${claude_cmd} --resume ${resume_token}" "Enter"
  else
    $TMUX_CMD send-keys -t "${session}:${win}.${pane_idx}" "$claude_cmd" "Enter"
  fi

done < "$RESURRECT_FILE"
