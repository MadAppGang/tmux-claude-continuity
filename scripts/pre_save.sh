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

# ── Clobber guard (runs at script exit, after enrichment) ────────────────────
# save.sh writes this snapshot to a NEW timestamped file and calls us BEFORE it
# repoints `last`. If the *current* `last` records many Claude sessions but the
# *final, enriched* new snapshot records ZERO, this save is almost certainly
# capturing a failed restore (all panes fell back to bare shells), not a real
# teardown. Letting it through repoints `last` at a tokenless snapshot and
# destroys resume continuity — the data-loss that turns a cosmetic restore
# glitch into a near-catastrophe.
#
# MUST run after the CLAUDE_SID enrichment below (a raw resurrect dump has zero
# sentinels — this script ADDS them — so an early check would block every save).
# We register it as an EXIT trap so it fires on every code path, including the
# early `exit 0` when no by-pid dir exists.
#
# Defuse a wipe by overwriting the new file with the current `last` contents.
# save.sh then sees them as identical (files_differ == false), deletes the new
# file, and leaves `last` pointing at the good snapshot. Triggers only on an
# exact-zero wipe, so legitimate pane closures (never exactly zero while others
# remain) pass through untouched.
clobber_guard() {
  local guard_log="$HOME/.tmux/scripts/claude-continuity-clobber-guard.log"
  local last_guard; last_guard="$(dirname "$SNAPSHOT_FILE")/last"
  [ -e "$last_guard" ] || return 0
  # Don't guard against ourselves: if save.sh hasn't repointed yet, `last` is the
  # PREVIOUS snapshot, never this one. (resolve to compare paths defensively)
  case "$(readlink "$last_guard" 2>/dev/null)" in
    "$(basename "$SNAPSHOT_FILE")") return 0 ;;
  esac
  local prev new
  prev="$(grep -c 'CLAUDE_SID' "$last_guard" 2>/dev/null)"; prev="${prev:-0}"
  new="$(grep -c 'CLAUDE_SID' "$SNAPSHOT_FILE" 2>/dev/null)"; new="${new:-0}"
  if [ "$prev" -ge 3 ] && [ "$new" -eq 0 ]; then
    mkdir -p "$(dirname "$guard_log")"
    printf '[%s] BLOCKED near-total-wipe save: last had %s CLAUDE_SID, new had 0 — keeping good snapshot\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$prev" >> "$guard_log"
    cat "$last_guard" > "$SNAPSHOT_FILE" 2>/dev/null || true
  fi
}
trap clobber_guard EXIT

# ── Repair collapsed pane lines (empty pane_title) ───────────────────────────
# tmux-resurrect's save format writes each pane as tab-separated columns:
#   1:pane 2:session 3:window 4:win_active 5::win_flags 6:pane_index
#   7:pane_title 8::pane_current_path 9:pane_active 10:cmd 11::full_command…
# (cols beyond 10 vary with process-restore mode; we only touch the 7/8 boundary)
# Columns 5, 8, and the full-command field carry a leading ':' sentinel so an
# empty value still occupies its slot. pane_title (col 7) has NO such sentinel.
# When a pane's title is empty (every non-Claude pane: zsh, bun, MCP procs), the
# field collapses, every later column shifts left by one, and restore.sh reads
# the pane_active flag ('0'/'1') as the directory. `split-window -c 1` then fails
# and tmux silently falls back to $HOME — restoring that pane in the wrong dir.
#
# Detection is exact: col 8 is ALWAYS ':'-prefixed in a healthy line (the path
# sentinel is hardcoded in save.sh). If col 8 does not start with ':', the row
# shifted and the ':'-prefixed path is sitting in col 7. We re-insert an empty
# title field at col 7 to realign. Idempotent: a repaired line has a ':' in col 8
# again, so a second pass skips it. Runs before the SID-enrichment early-exit so
# the directory fix applies on every save, even with no Claude panes present.
realigned="${SNAPSHOT_FILE}.realign.$$"
if awk -F'\t' 'BEGIN { OFS = "\t" }
  $1 == "pane" && $8 !~ /^:/ {
    # Title was empty -> path leaked into col 7. Shift cols 7..NF right by one
    # and clear col 7 so pane_current_path lands back in col 8.
    for (i = NF; i >= 7; i--) $(i + 1) = $i
    $7 = ""
  }
  { print }
' "$SNAPSHOT_FILE" > "$realigned" && [ -s "$realigned" ]; then
  mv "$realigned" "$SNAPSHOT_FILE"
else
  rm -f "$realigned"
fi

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
# Keep the clobber_guard on EXIT and add temp-file cleanup ahead of it.
trap 'rm -f "$declare_map_file" "${SNAPSHOT_FILE}.enrich.$$"; clobber_guard' EXIT

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
# Drop the temp-cleanup+guard trap (temps already cleaned) and run the guard
# once, explicitly, against the now-enriched snapshot.
trap - EXIT
clobber_guard
