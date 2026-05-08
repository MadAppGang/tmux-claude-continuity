#!/usr/bin/env bash
# pre_save.sh — tmux-resurrect post-save-layout hook
#
# Triggered by: @resurrect-hook-post-save-layout (called with snapshot path as $1)
# Fires immediately after tmux-resurrect writes the snapshot file. We mutate
# the snapshot in place to embed each Claude pane's session ID directly in
# its pane line.
#
# Why: the position-keyed sidecar (~/.config/tmux-claude/panes/<S>-<W>-<P>.session-id)
# drifts when tmux windows are renumbered/moved/swapped between save and
# restore. Embedding the ID at save time, when the running PID is still
# reachable from the live tmux server, makes the snapshot self-contained
# and immune to position changes.
#
# Format: each enriched pane line gets an additional tab-separated field
# at the end:  ;CLAUDE_SID=<uuid>
# This sentinel-prefixed format is ignored by older post_restore.sh versions
# (extra trailing data is benign) and parsed by the updated one.

set -u

SNAPSHOT_FILE="${1:-}"
[ -n "$SNAPSHOT_FILE" ] && [ -f "$SNAPSHOT_FILE" ] || exit 0

panes_dir="$(tmux show-option -gqv @claude-continuity-panes-dir 2>/dev/null)"
panes_dir="${panes_dir:-$HOME/.config/tmux-claude/panes}"
by_pid_dir="${panes_dir}/by-pid"

[ -d "$by_pid_dir" ] || exit 0

# ── Garbage collect orphaned PID-keyed sidecars ──────────────────────────────
for f in "${by_pid_dir}"/*.session-id; do
  [ -f "$f" ] || continue
  pid="$(basename "$f" .session-id)"
  case "$pid" in
    *[!0-9]*) rm -f "$f"; continue ;;
  esac
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$f"
  fi
done

# ── Build pane → session_id mapping from live tmux state ─────────────────────
# For each tmux pane, look at its child PIDs and check the by-pid sidecar dir.
# Whichever child has a registered session ID is the Claude process for that
# pane. Output: one line per pane with format "<S>:<W>.<P> <session_id>".
declare_map_file="${SNAPSHOT_FILE}.sidmap.$$"
trap 'rm -f "$declare_map_file" "${SNAPSHOT_FILE}.enrich.$$"' EXIT

tmux list-panes -a -F '#S	#I	#P	#{pane_pid}' 2>/dev/null | \
while IFS=$'\t' read -r sess win pane shell_pid; do
  [ -n "$shell_pid" ] || continue
  for child in $(pgrep -P "$shell_pid" 2>/dev/null); do
    if [ -f "${by_pid_dir}/${child}.session-id" ]; then
      sid="$(head -1 "${by_pid_dir}/${child}.session-id")"
      [ -n "$sid" ] && printf '%s:%s.%s\t%s\n' "$sess" "$win" "$pane" "$sid"
      break
    fi
  done
done > "$declare_map_file"

# ── Enrich the snapshot ──────────────────────────────────────────────────────
tmp="${SNAPSHOT_FILE}.enrich.$$"

while IFS=$'\t' read -r line_type rest; do
  if [ "$line_type" != "pane" ]; then
    printf '%s\t%s\n' "$line_type" "$rest"
    continue
  fi

  # Pane line layout (tab-separated, as written by tmux-resurrect's save.sh):
  #   pane <session> <window> <win_active> <win_flags> <pane_idx> <title> <dir> ...
  # We only need session, window, pane_idx (columns 2, 3, 6 of the original).
  # After splitting off line_type, "rest" begins at column 2.
  IFS=$'\t' read -r r_sess r_win _r_winact _r_winflags r_pane _r_rest <<EOF
$rest
EOF
  pane_target="${r_sess}:${r_win}.${r_pane}"

  matched_sid="$(awk -F'\t' -v t="$pane_target" '$1 == t {print $2; exit}' "$declare_map_file")"

  if [ -n "$matched_sid" ]; then
    printf '%s\t%s\t;CLAUDE_SID=%s\n' "$line_type" "$rest" "$matched_sid"
  else
    printf '%s\t%s\n' "$line_type" "$rest"
  fi
done < "$SNAPSHOT_FILE" > "$tmp"

mv "$tmp" "$SNAPSHOT_FILE"
rm -f "$declare_map_file"
trap - EXIT
