#!/usr/bin/env bash
# heal_lost_cwd.sh — regression test for healing panes scarred by the old
# empty-title column shift.
#
# A pane whose title was empty collapsed its snapshot row, so restore applied the
# ':'-prefixed PATH as the pane TITLE and the pane itself landed in $HOME. That
# state perpetuates: the next save writes a well-formed row (non-empty title,
# ':'-prefixed path) recording $HOME, so pre_save's realign correctly finds
# nothing to fix and the pane returns to $HOME on every restore, forever.
#
# post_restore.sh now reunites the two: title says where the pane belongs, so
# queue a `cd` through the pending-file path and clear the bogus title.
#
# Isolation: own tmux socket with `-f /dev/null`, own pending/log dirs. Panes run
# an inert `sh` loop, so nothing consumes the pending file and we can assert on
# its exact contents.
#
# Usage: bash tests/heal_lost_cwd.sh   (exit 0 = pass)

set -uo pipefail

# ── RESURRECT SAVE-SIDE ISOLATION ────────────────────────────────────────────
# RESURRECT_FILE redirects resurrect READS. Only @resurrect-dir redirects its
# WRITES. A test that triggers a save without setting it deposits fixture
# snapshots in the user's live resurrect directory and can leave `last`
# pointing at one. See tests/lib/resurrect_guard.sh for the measured damage.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed work legacy alpha beta lvl cA cB cC cD cE

SOCKET="cchl$$"
TD="/tmp/cchl-$$"
QD="$TD/pending"
RD="$TD/resurrect"
LOG="$TD/restore.log"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
RESTORE_SCRIPT="$SCRIPT_DIR/post_restore.sh"

# A real directory for the pane to be sent back to, and one that does not exist.
WANT="$TD/project"
GONE="$TD/deleted-since"

pass=0
fail=0

_tmux() { tmux -L "$SOCKET" -f /dev/null "$@"; }
_teardown() { tmux -L "$SOCKET" kill-server 2>/dev/null; rm -rf "$TD"; }
# Re-wrap the teardown so a leak into the real resurrect dir fails the run
# even on the early-abort paths that never reach the final assertions.
_cc_teardown_guarded() { _teardown; cc_warn_on_resurrect_leak || exit 1; }
trap _cc_teardown_guarded EXIT INT TERM

mkdir -p "$QD" "$RD" "$WANT"

ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; [ $# -gt 1 ] && echo "    $2"; fail=$((fail+1)); }
assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "got '$got', want '$want'"; fi
}

# An empty snapshot: no pane rows, so the resume loop does nothing and we are
# testing the heal in isolation.
printf 'window\twork\t0\t:*\t1\tmain\n' > "$RD/last"

INERT="sh -c 'while :; do sleep 5; done'"

# -c sets each pane's starting directory: panes otherwise inherit the cwd of
# whatever invoked the test, and "is this pane sitting in \$HOME" is the entire
# trigger condition. -P -F prints the new pane id, so the four cases are captured
# at creation instead of guessed from list-panes order (splits renumber).
_tmux new-session -d -s work -c "$HOME" "$INERT"
_tmux set-option -g @claude-continuity-pending-dir "$QD" >/dev/null
_tmux set-option -g @claude-continuity-log-file "$LOG" >/dev/null
_tmux set-option -g @resurrect-dir "$RD" >/dev/null
# Pre-flight: ask the SERVER what it will actually use and refuse to run if
# the answer is the user's real directory. A set-option that ran too early or
# at the wrong scope leaves the default in place, and only asking catches it.
cc_guard_resurrect_dir "$RD" tmux -L "$SOCKET" -f /dev/null

SCARRED="$(_tmux list-panes -t work -F '#{pane_id}' | head -1)"       # $HOME + ":/real"  -> heal
STALE="$(_tmux split-window -t work -d -c "$HOME" -P -F '#{pane_id}' "$INERT")"   # $HOME + ":/gone" -> skip
RIGHTDIR="$(_tmux split-window -t work -d -c "$WANT" -P -F '#{pane_id}' "$INERT")" # right cwd, bogus title
PLAIN="$(_tmux split-window -t work -d -c "$HOME" -P -F '#{pane_id}' "$INERT")"    # $HOME, no title
sleep 0.5

_tmux select-pane -t "$SCARRED"  -T ":$WANT"
_tmux select-pane -t "$STALE"    -T ":$GONE"
_tmux select-pane -t "$RIGHTDIR" -T ":$WANT"
_tmux select-pane -t "$PLAIN"    -T ""

echo "[0] PREMISE: panes are in \$HOME with the expected titles"
CWD0="$(_tmux display-message -p -t "$SCARRED" '#{pane_current_path}')"
assert_eq "scarred pane starts in \$HOME" "$CWD0" "$HOME"

TMUX_CMD="tmux -L $SOCKET -f /dev/null" bash "$RESTORE_SCRIPT" >/dev/null 2>&1

echo "[1] THE FIX: a pane in \$HOME whose title carries a real path is sent back"
assert_eq "queued 'cd <path>' in the pending file" \
  "$(cat "$QD/${SCARRED#%}" 2>/dev/null)" "cd $WANT"
assert_eq "bogus title cleared" \
  "$(_tmux display-message -p -t "$SCARRED" '#{pane_title}')" ""

echo "[2] SAFETY: a title pointing at a path that no longer exists is left alone"
if [ -e "$QD/${STALE#%}" ]; then
  bad "no cd queued for a vanished path" "pending file exists: $(cat "$QD/${STALE#%}")"
else
  ok "no cd queued for a vanished path"
fi

echo "[3] TITLE-ONLY SCAR: cwd already correct, so clear the title but do not cd"
if [ -e "$QD/${RIGHTDIR#%}" ]; then
  bad "no cd queued when the cwd is already right" "pending file exists"
else
  ok "no cd queued when the cwd is already right"
fi
assert_eq "title still cleared (else the scar outlives the repair)" \
  "$(_tmux display-message -p -t "$RIGHTDIR" '#{pane_title}')" ""

echo "[4] UNRELATED PANES: an ordinary untitled pane is untouched"
if [ -e "$QD/${PLAIN#%}" ]; then
  bad "ordinary pane untouched" "pending file exists"
else
  ok "ordinary pane untouched"
fi

echo "[5] A QUEUED RESUME OWNS THE SLOT: healing never displaces it"
rm -f "$QD"/*
_tmux select-pane -t "$SCARRED" -T ":$WANT"
printf 'c --resume some-session-id\n' > "$QD/${SCARRED#%}"
TMUX_CMD="tmux -L $SOCKET -f /dev/null" bash "$RESTORE_SCRIPT" >/dev/null 2>&1
assert_eq "existing resume left intact" \
  "$(cat "$QD/${SCARRED#%}" 2>/dev/null)" "c --resume some-session-id"

echo "=================================================================="
echo "  RESULT: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
