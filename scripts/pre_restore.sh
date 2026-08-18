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
#
# But this must NOT be a blanket delete, and it was. This script runs from TWO
# places: the resurrect pre-restore hook, and a bare `run-shell` in .tmux.conf
# that fires on EVERY config parse — every `tmux source-file`, not only a
# restore. A blanket purge therefore destroyed every LIVE pane's recorded command
# on any config reload, with no restore following to re-record it.
#
# Measured on 2026-08-18: 47 files purged at 12:05:49 with no BOOT VERDICT after
# it, and the 21:19 snapshot carried CLAUDE_CMD on 1 of 41 Claude rows. Every
# restore then logged `cmd=default`, so @claude-continuity-claude-cmd silently
# carried 100% of the relaunches — which made the typed-command path look like it
# had never worked, when in fact it worked and was being erased.
#
# The discriminator is the SERVER START TIME. A file written by a shell in this
# server is newer than the server; a dead server's residue is older. That keeps
# live panes intact across a config reload and still drops stale ids on a fresh
# server, where pane ids restart at %0 and would otherwise collide.
#
# `#{start_time}` needs tmux >= 3.2. When it is missing or unparseable the
# blanket purge is the correct fallback: losing recorded commands is recoverable,
# resuming a dead session's SID into the wrong pane is not.
launch_dir="$($TMUX_CMD show-option -gqv @claude-continuity-launch-dir 2>/dev/null)"
launch_dir="${launch_dir:-$HOME/.config/tmux-claude/launch}"

_cc_server_start="$($TMUX_CMD display-message -p '#{start_time}' 2>/dev/null)"
case "$_cc_server_start" in
  ''|*[!0-9]*) _cc_server_start="" ;;
esac

_cc_lpurged=0
_cc_lkept=0
if [ -d "$launch_dir" ]; then
  for f in "$launch_dir"/*; do
    [ -f "$f" ] || continue
    case "${f##*/}" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ -n "$_cc_server_start" ]; then
      # BSD stat first (macOS), GNU second — the plugin runs on both.
      _cc_mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)"
      case "$_cc_mtime" in
        ''|*[!0-9]*) _cc_mtime=0 ;;
      esac
      if [ "$_cc_mtime" -ge "$_cc_server_start" ]; then
        _cc_lkept=$((_cc_lkept + 1))
        continue
      fi
    fi
    rm -f "$f" && _cc_lpurged=$((_cc_lpurged + 1))
  done
fi
if [ "$_cc_lkept" -gt 0 ]; then
  _cc_log "pre_restore: purged $_cc_lpurged stale launch-command file(s) from $launch_dir (kept $_cc_lkept written in this server)"
else
  _cc_log "pre_restore: purged $_cc_lpurged stale launch-command file(s) from $launch_dir"
fi
exit 0
