#!/usr/bin/env bash
# pre_restore.sh — tmux-resurrect pre-restore hook
#
# Triggered by: @resurrect-hook-pre-restore-all (restore.sh:369, undocumented)
# Fires BEFORE restore_all_panes creates a single pane — which is the only
# moment this can safely run.
#
# Purges stale pending-resume files. post_restore.sh keys each pending file by
# LIVE tmux pane id (%N), and pane ids restart at %0 on every fresh server, so a
# file left over from an earlier restore is indistinguishable — to the precmd
# hook that consumes it — from one written for the pane sitting at that id now.
# It will be consumed, resuming whatever session that older restore promised.
#
# Not theoretical. On the 2026-07-22 boot, panes %0 and %48 launched claude at
# 22:49:14–16, six to eight seconds BEFORE post_restore ran at 22:49:22, in a
# command form that run could not produce — they had eaten pending files from a
# previous restore. post_restore then wrote 40 fresh files into panes already
# running claude; 36 were still sitting unconsumed hours later, armed to fire on
# the next boot.
#
# Purging HERE rather than at the top of post_restore.sh is the whole point:
# restored shells reach their first prompt during restore_all_panes, so anything
# that runs after the panes exist is already too late to stop a stale file from
# being consumed.

TMUX_CMD="${TMUX_CMD:-tmux}"

LOG_FILE="$($TMUX_CMD show-option -gqv @claude-continuity-log-file 2>/dev/null)"
LOG_FILE="${LOG_FILE:-$HOME/.tmux/scripts/claude-continuity-restore.log}"
_cc_log() {
  # Best-effort: never let logging failure abort a restore.
  { mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null && \
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; } 2>/dev/null || true
}

pending_dir="$($TMUX_CMD show-option -gqv @claude-continuity-pending-dir 2>/dev/null)"
pending_dir="${pending_dir:-$HOME/.config/tmux-claude/pending}"

# Delete ONLY files this plugin creates: pending files are named for a tmux pane
# id with the '%' stripped, so the name is always all digits. Without that check,
# an @claude-continuity-pending-dir accidentally pointed at $HOME (or left unset
# against a future default) turns this loop into an unbounded delete of the
# user's files. The narrow pattern makes a misconfiguration inert instead.
_cc_purged=0
_cc_kept=0
if [ -d "$pending_dir" ]; then
  for f in "$pending_dir"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in
      ''|*[!0-9]*) _cc_kept=$((_cc_kept + 1)); continue ;;
    esac
    rm -f "$f" && _cc_purged=$((_cc_purged + 1))
  done
fi

if [ "$_cc_kept" -gt 0 ]; then
  _cc_log "pre_restore: purged $_cc_purged stale pending resume file(s) from $pending_dir (left $_cc_kept non-pending file(s) untouched)"
else
  _cc_log "pre_restore: purged $_cc_purged stale pending resume file(s) from $pending_dir"
fi

# Same reasoning for the recorded launch commands: they are keyed by pane id too,
# so a dead server's file would be attributed to whatever pane inherits that id.
# Safe to drop — the snapshot already carries the commands for this restore, and
# each restored pane re-records its own on relaunch.
launch_dir="$($TMUX_CMD show-option -gqv @claude-continuity-launch-dir 2>/dev/null)"
launch_dir="${launch_dir:-$HOME/.config/tmux-claude/launch}"
_cc_lpurged=0
if [ -d "$launch_dir" ]; then
  for f in "$launch_dir"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in
      ''|*[!0-9]*) continue ;;
    esac
    rm -f "$f" && _cc_lpurged=$((_cc_lpurged + 1))
  done
fi
_cc_log "pre_restore: purged $_cc_lpurged stale launch-command file(s) from $launch_dir"
exit 0
