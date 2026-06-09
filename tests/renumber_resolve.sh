#!/usr/bin/env bash
# renumber_resolve.sh — regression test for window-renumber drift.
#
# Reproduces the failure where tmux `renumber-windows on` moves a claude pane to
# a different window index between save and restore. The old post_restore.sh
# resolved the live pane by the snapshot's session:window.pane coordinate, which
# tmux resolves FUZZILY (a missing window index silently resolves to a nearby
# pane), so the resume was misrouted into the wrong pane. The fix resolves by
# content (session + cwd + title) instead, so the resume lands on the right pane
# regardless of renumbering.
#
# Fully isolated: runs on its own tmux socket with `-f /dev/null` (NO user
# config, so the boot auto-restore never fires and nothing touches live state).
#
# Usage: bash tests/renumber_resolve.sh   (exit 0 = pass)

set -uo pipefail

SOCKET="ccrn$$"
QD="/tmp/ccrn-pend-$$"
RD="/tmp/ccrn-res-$$"
LOG="/tmp/ccrn-$$.log"
RF="$RD/last"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
RESTORE_SCRIPT="$SCRIPT_DIR/post_restore.sh"

pass=0
fail=0

_tmux() { tmux -L "$SOCKET" "$@"; }

_teardown() {
  _tmux kill-server 2>/dev/null
  rm -rf "$QD" "$RD" "$LOG"
}
trap _teardown EXIT

mkdir -p "$QD" "$RD"

# ── Build an isolated server with a deterministic window layout ──────────────
# A fresh `-f /dev/null` server starts with one window at index 0. We set
# base-index AFTER that and renumber so indices are predictable; then we create
# named target windows and verify each exists before continuing.
_tmux -f /dev/null new-session -d -s work -c /tmp
_tmux set-option -g base-index 1
_tmux set-option -g pane-base-index 1
_tmux set-option -g renumber-windows on

# Create three windows; capture the live id of the one we'll treat as "window 3".
_tmux new-window -t work -c /tmp        # a
_tmux new-window -t work -c /tmp        # b  (the TARGET)
_tmux new-window -t work -c /tmp        # c

# Identify the target by giving its CURRENT window a unique title, then record
# that window's index + pane id. We pick the middle of the three newly-created
# windows as the target.
# bash 3.2 (macOS) has no `mapfile`; collect window indices into a positional list.
set --
while IFS= read -r _wi; do
  [ -n "$_wi" ] && set -- "$@" "$_wi"
done < <(_tmux list-windows -t work -F '#{window_index}')
n="$#"
if [ "$n" -lt 3 ]; then
  echo "SETUP FAIL: expected >=3 windows, got $n"
  exit 1
fi
# target = 2nd of the three created = ($n - 1)th positional (1-based)
eval "target_win=\${$((n - 1))}"
target_id="$(_tmux list-panes -t "work:${target_win}" -F '#{pane_id}' | head -1)"
target_cwd="$(_tmux list-panes -t "work:${target_win}" -F '#{pane_current_path}' | head -1)"
_tmux select-pane -t "$target_id" -T "Debug skills"

# Kill the window BEFORE the target so renumber shifts the target's index down.
# = 1st of the three created = ($n - 2)th positional (1-based).
eval "kill_win=\${$((n - 2))}"
_tmux kill-window -t "work:${kill_win}"

# After renumber, the target keeps its pane id ($target_id) but its window index
# has changed. The snapshot still references the OLD (pre-kill) window index.
stale_win="$target_win"   # the index the snapshot recorded

echo "Target pane: $target_id (snapshot says window $stale_win, killed window $kill_win)"

# ── Configure continuity + write the stale snapshot row ──────────────────────
_tmux set-option -g @claude-continuity-claude-cmd "echo"
_tmux set-option -g @claude-continuity-pending-dir "$QD"
_tmux set-option -g @claude-continuity-log-file "$LOG"

# Snapshot row: claude pane recorded at the STALE window index, with the target's
# real cwd + title and an embedded resume token. dir field carries ':' sentinel.
printf 'pane\twork\t%s\t1\t:*\t1\tDebug skills\t:%s\t1\tclaude\t:claude --dangerously-skip-permissions\t;CLAUDE_SID=sid-DRIFT\n' \
  "$stale_win" "$target_cwd" > "$RF"

# ── Run the real post_restore.sh ─────────────────────────────────────────────
TMUX_CMD="tmux -L $SOCKET" RESURRECT_FILE="$RF" bash "$RESTORE_SCRIPT"

# ── Assert: the resume landed on the TARGET pane, by content, not misrouted ──
expected_file="$QD/${target_id#%}"
if [ -f "$expected_file" ] && grep -q "resume sid-DRIFT" "$expected_file"; then
  echo "  PASS: resume written to correct pane $target_id (content-matched)"
  ((pass++))
else
  echo "  FAIL: resume not on target pane $target_id"
  echo "    pending files written:"; ls -1 "$QD" 2>/dev/null | sed 's/^/      %/'
  echo "    log:"; grep -E 'WROTE|SKIP' "$LOG" 2>/dev/null | sed 's/^/      /'
  ((fail++))
fi

# ── Assert: the match was by content, not coord-fallback ─────────────────────
if grep -q "content,.*Debug skills" "$LOG" 2>/dev/null; then
  echo "  PASS: resolved by content (drift-proof path)"
  ((pass++))
else
  echo "  FAIL: did not resolve by content"
  grep -E 'WROTE|SKIP' "$LOG" 2>/dev/null | sed 's/^/      /'
  ((fail++))
fi

echo ""
echo "  Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
