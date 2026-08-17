#!/usr/bin/env bash
# dup_title_resolve.sh — regression test for the duplicate-title collision.
#
# Two Claude panes in the same session can share an identical (cwd, title) —
# e.g. several panes titled "Claude Code". The content resolver must pair the N
# snapshot rows to N DISTINCT live panes, never collapse them onto one.
#
# Original bug: _cc_resolve_by_content mutated its used-id set inside a COMMAND
# SUBSTITUTION (pane_id="$(...)"), so the mutation was lost in the subshell and
# every duplicate-title row resolved to the SAME first pane, overwriting each
# other's pending file (one session lost per collision).
#
# Robust setup: we do NOT hardcode cwd / window-index / title — tmux normalizes
# cwd (/tmp -> /private/tmp on macOS) and applies base-index at its own moment.
# Instead we read the ACTUAL live (session,window,pane,cwd,title) and build the
# snapshot rows from those, so content-match is exercised on truthful values.
#
# Fully isolated: own tmux socket, -f /dev/null (no user config / no auto-restore).
# Usage: bash tests/dup_title_resolve.sh   (exit 0 = pass)

set -uo pipefail

# ── RESURRECT SAVE-SIDE ISOLATION ────────────────────────────────────────────
# RESURRECT_FILE redirects resurrect READS. Only @resurrect-dir redirects its
# WRITES. A test that triggers a save without setting it deposits fixture
# snapshots in the user's live resurrect directory and can leave `last`
# pointing at one. See tests/lib/resurrect_guard.sh for the measured damage.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed work legacy alpha beta lvl cA cB cC cD cE

SOCKET="ccdt$$"
QD="/tmp/ccdt-pend-$$"
RD="/tmp/ccdt-res-$$"
LOG="/tmp/ccdt-$$.log"
RF="$RD/last"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
RESTORE_SCRIPT="$SCRIPT_DIR/post_restore.sh"

pass=0; fail=0
# An empty or "default" socket label would aim every command in this file at the
# user's real server; refuse before defining the wrapper. -f /dev/null then stops
# the throwaway server sourcing ~/.tmux.conf and restoring the real estate into
# itself (see claudish_restore.sh).
case "$SOCKET" in default|"") echo "unsafe socket [$SOCKET]"; exit 1 ;; esac
_t(){ tmux -L "$SOCKET" -f /dev/null "$@"; }
_teardown(){ _t kill-server 2>/dev/null; rm -rf "$QD" "$RD" "$LOG"; }
# Re-wrap the teardown so a leak into the real resurrect dir fails the run
# even on the early-abort paths that never reach the final assertions.
_cc_teardown_guarded() { _teardown; cc_warn_on_resurrect_leak || exit 1; }
trap _cc_teardown_guarded EXIT
mkdir -p "$QD" "$RD"

# One session, two panes; title both identically to force a duplicate group.
_t -f /dev/null new-session -d -s work -c /tmp
_t split-window -t work -c /tmp
DUP_TITLE="Claude Code DUP"
for p in $(_t list-panes -t work -F '#{pane_id}'); do _t select-pane -t "$p" -T "$DUP_TITLE"; done

# The SAVE side. Without this, any save resurrect performs lands in the user's
# live directory: helpers.sh defaults there whenever the option is unset.
_t set-option -g @resurrect-dir "$RD"
cc_guard_resurrect_dir "$RD" tmux -L "$SOCKET" -f /dev/null
_t set-option -g @claude-continuity-claude-cmd "echo"
_t set-option -g @claude-continuity-pending-dir "$QD"
_t set-option -g @claude-continuity-log-file "$LOG"

# Read the ACTUAL live layout for the two panes and build snapshot rows from it.
# Fields: window_index, pane_index, pane_id, cwd, title (all as tmux reports).
i=0
while IFS='|' read -r w p pid cwd title; do
  i=$((i+1))
  eval "w$i=$w; p$i=$p; id$i=$pid; cwd$i=\$cwd; title$i=\$title"
done < <(_t list-panes -t work -F '#{window_index}|#{pane_index}|#{pane_id}|#{pane_current_path}|#{pane_title}')

# Two snapshot rows: identical (session,cwd,title), DIFFERENT SIDs, using the
# real window/pane indices + the real cwd (with the ':' sentinel pre_save adds).
# win_active/win_flags/pane_active values are cosmetic for this path.
printf 'pane\twork\t%s\t1\t:*\t%s\t%s\t:%s\t1\tclaude\t:claude\t;CLAUDE_SID=sid-AAA\n' "$w1" "$p1" "$title1" "$cwd1"  > "$RF"
printf 'pane\twork\t%s\t0\t:-\t%s\t%s\t:%s\t0\tclaude\t:claude\t;CLAUDE_SID=sid-BBB\n' "$w2" "$p2" "$title2" "$cwd2" >> "$RF"

TMUX_CMD="tmux -L $SOCKET" RESURRECT_FILE="$RF" bash "$RESTORE_SCRIPT"

# Assert against the LOG (the authoritative record of post_restore's decisions).
# We deliberately do NOT assert on surviving pending files: the test uses `echo`
# as the claude-cmd, so the post-write `send-keys Enter` makes the echo-pane run
# and exit, which can race-remove the freshly-written file. The log's WROTE
# lines record exactly which pane each SID was routed to — that's what matters.
wrote_lines="$(grep 'WROTE' "$LOG" 2>/dev/null)"

# (1) Both rows resolved via CONTENT match (the dedup path), not coord-fallback.
content_writes=$(printf '%s\n' "$wrote_lines" | grep -c '(content,'); content_writes=${content_writes:-0}
if [ "$content_writes" -eq 2 ]; then
  echo "  PASS: both rows resolved via content-match (dedup path exercised)"; pass=$((pass+1))
else
  echo "  FAIL: expected 2 content-matches, got $content_writes"; fail=$((fail+1))
  printf '%s\n' "$wrote_lines" | sed 's/^/      /'; grep SKIP "$LOG" 2>/dev/null | sed 's/^/      /'
fi

# (2) Both DISTINCT SIDs were written (neither overwritten by a collision).
for sid in sid-AAA sid-BBB; do
  if printf '%s\n' "$wrote_lines" | grep -q "resume=$sid"; then
    echo "  PASS: $sid routed (not lost to collision)"; pass=$((pass+1))
  else
    echo "  FAIL: $sid missing — collision overwrote it"; fail=$((fail+1))
  fi
done

# (3) The two SIDs went to TWO DISTINCT pane ids (the core of the dedup fix).
distinct_targets=$(printf '%s\n' "$wrote_lines" | grep -oE '> %[0-9]+' | sort -u | wc -l | tr -d ' ')
if [ "$distinct_targets" -eq 2 ]; then
  echo "  PASS: routed to 2 distinct panes (no collision onto one)"; pass=$((pass+1))
else
  echo "  FAIL: routed to $distinct_targets distinct pane(s) — collision"; fail=$((fail+1))
fi

echo ""
echo "  Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
