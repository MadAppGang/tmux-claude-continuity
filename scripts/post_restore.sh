#!/usr/bin/env bash
# post_restore.sh — tmux-resurrect post-restore hook
#
# Triggered by: @resurrect-hook-post-restore-all (restore.sh:382, undocumented)
# Fires after all panes, processes, zoom states, and sessions are restored.
#
# For each pane that was running claude, reads the saved session ID from the
# per-pane sidecar file and sends `claude --resume <uuid>` to that pane.

RESURRECT_FILE="$HOME/.local/share/tmux/resurrect/last"

panes_dir="$(tmux show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"

restore_delay="$(tmux show-option -gqv @claude-continuity-restore-delay 2>/dev/null)"
restore_delay="${restore_delay:-1}"

claude_flags="$(tmux show-option -gqv @claude-continuity-claude-flags 2>/dev/null)"
claude_flags="${claude_flags:---dangerously-skip-permissions}"

if [ ! -f "$RESURRECT_FILE" ]; then
  exit 0
fi

# Give shells time to finish sourcing rc files after restore
sleep "$restore_delay"

while IFS=$'\t' read -r line_type session win win_active win_flags pane_idx \
        pane_title dir pane_active pane_cmd pane_full_cmd; do
  [ "$line_type" = "pane" ] || continue

  # Strip leading ":" sentinel from full command field
  full_cmd="${pane_full_cmd#:}"

  # Only act on panes that were running claude
  [[ "$full_cmd" == *"claude"* ]] || continue

  pane_key="${session}-${win}-${pane_idx}"
  metadata_file="${panes_dir}/${pane_key}.session-id"

  if [ ! -f "$metadata_file" ]; then
    # No saved session ID — start fresh
    tmux send-keys -t "${session}:${win}.${pane_idx}" \
      "claude ${claude_flags}" "Enter"
    continue
  fi

  resume_token="$(cat "$metadata_file")"

  if [ -n "$resume_token" ]; then
    tmux send-keys -t "${session}:${win}.${pane_idx}" \
      "claude --resume ${resume_token} ${claude_flags}" "Enter"
  else
    tmux send-keys -t "${session}:${win}.${pane_idx}" \
      "claude ${claude_flags}" "Enter"
  fi

done < "$RESURRECT_FILE"
