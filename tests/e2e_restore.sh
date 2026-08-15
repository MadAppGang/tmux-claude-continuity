#!/usr/bin/env bash
# e2e_restore.sh — end-to-end test for post_restore.sh
#
# Runs the REAL post_restore.sh against an isolated tmux socket and asserts on
# the restore LOG (post_restore's authoritative record of what it routed where).
#
# WHY THE LOG, NOT PANE OUTPUT: current post_restore does NOT send the command
# via send-keys — it writes a per-pane "pending resume" file that the pane's own
# precmd hook consumes on first prompt. So the command never appears in captured
# pane output, and the pending file is race-consumed by the pane's zsh. The log's
# WROTE/SKIP lines are the stable, authoritative record (same approach as
# dup_title_resolve.sh). Resume tokens come ONLY from the snapshot's
# ;CLAUDE_SID=<uuid> field — post_restore deliberately ignores position-keyed
# sidecar files (they drift), so fixtures embed the SID in the row, not a file.
#
# SAFETY (a plain `tmux -L x new-session` sources ~/.tmux.conf, whose continuum
# auto-restore then restores the user's ENTIRE real layout into the test server —
# duplicating every claude and arming a timer that clobbers the real snapshot):
#   * -f /dev/null           -> config-free server, no hooks, no auto-restore
#   * pending/log/panes/resurrect dirs all redirected under $TMPROOT
#   * isolation asserted (exactly one session) before any test runs
#   * never kill-server; only kill sessions on our own socket
#
# Usage: bash tests/e2e_restore.sh
# Exit code: 0 = all pass, 1 = failure

set -uo pipefail

# ── RESURRECT SAVE-SIDE ISOLATION ────────────────────────────────────────────
# RESURRECT_FILE redirects resurrect READS. Only @resurrect-dir redirects its
# WRITES. A test that triggers a save without setting it deposits fixture
# snapshots in the user's live resurrect directory and can leave `last`
# pointing at one. See tests/lib/resurrect_guard.sh for the measured damage.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed work legacy alpha beta lvl cA cB cC cD cE

SOCKET="tctest$$"
TMPROOT="/tmp/tctest-$$"
PANES_DIR="$TMPROOT/panes"
PENDING_DIR="$TMPROOT/pending"
RESURRECT_DIR="$TMPROOT/resurrect"
RESURRECT_FILE="$RESURRECT_DIR/last"
LOG_FILE="$TMPROOT/restore.log"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
RESTORE_SCRIPT="$SCRIPT_DIR/post_restore.sh"
TEST_CMD="echo"

pass=0
fail=0

case "$SOCKET" in default|"") echo "unsafe socket label"; exit 1 ;; esac

_t() { tmux -L "$SOCKET" "$@"; }

_cleanup_test_socket() {
  for s in $(_t list-sessions -F '#{session_name}' 2>/dev/null); do
    _t kill-session -t "$s" 2>/dev/null
  done
}

cleanup() {
  _cleanup_test_socket
  # Kill any lingering server bound to OUR socket label only. $2 must literally be
  # tmux, else this awk matches its own `-L <socket>` command line and self-kills.
  for p in $(ps -Ao pid,command= | awk -v s="-L $SOCKET" '$2 ~ /(^|\/)tmux$/ && index($0,s){print $1}'); do
    kill "$p" 2>/dev/null
  done
  rm -rf "$TMPROOT"
}
# Re-wrap the teardown so a leak into the real resurrect dir fails the run
# even on the early-abort paths that never reach the final assertions.
_cc_teardown_guarded() { cleanup; cc_warn_on_resurrect_leak || exit 1; }
trap _cc_teardown_guarded EXIT

# ── Assertions (all operate on the restore log unless noted) ──────────────────
_log() { cat "$LOG_FILE" 2>/dev/null; }

assert_log_has() {
  local label="$1" needle="$2"
  if _log | grep -qF "$needle"; then
    echo "  PASS: $label"; pass=$((pass+1))
  else
    echo "  FAIL: $label"; echo "    expected log to contain: $needle"
    _log | sed 's/^/      log| /'; fail=$((fail+1))
  fi
}

assert_log_lacks() {
  local label="$1" needle="$2"
  if _log | grep -qF "$needle"; then
    echo "  FAIL: $label (log unexpectedly contains: $needle)"
    _log | sed 's/^/      log| /'; fail=$((fail+1))
  else
    echo "  PASS: $label"; pass=$((pass+1))
  fi
}

assert_not_exists() {
  local label="$1" path="$2"
  if [ ! -e "$path" ]; then echo "  PASS: $label"; pass=$((pass+1))
  else echo "  FAIL: $label (file still exists: $path)"; fail=$((fail+1)); fi
}

# ── Isolated server ───────────────────────────────────────────────────────────
_fresh_server() {
  local num_windows="${1:-1}"
  _cleanup_test_socket
  rm -rf "$PANES_DIR" "$PENDING_DIR"; mkdir -p "$PANES_DIR/by-pid" "$PENDING_DIR"
  : > "$LOG_FILE"   # each test asserts only on its own restore
  _t -f /dev/null new-session -d -s work -c /tmp
  local i
  for ((i = 2; i <= num_windows; i++)); do
    _t new-window -t work -c /tmp
  done
  _t set-option -g @claude-continuity-claude-cmd   "$TEST_CMD"
  _t set-option -g @claude-continuity-panes-dir    "$PANES_DIR"
  _t set-option -g @claude-continuity-pending-dir  "$PENDING_DIR"
  _t set-option -g @claude-continuity-log-file     "$LOG_FILE"
  _t set-option -g @resurrect-dir                  "$RESURRECT_DIR"
  # Pre-flight: ask the SERVER what it will actually use and refuse to run if
  # the answer is the user's real directory. A set-option that ran too early or
  # at the wrong scope leaves the default in place, and only asking catches it.
  cc_guard_resurrect_dir "$RESURRECT_DIR" tmux -L "$SOCKET" -f /dev/null
}

# Emit a snapshot pane row from the Nth live pane's REAL (window,pane,cwd,title)
# so post_restore's content-resolution matches. Args: N full_cmd [sid]
# Reads the live layout each call (cheap; test panes are few).
_row_from_live() {
  local n="$1" full_cmd="$2" sid="${3:-}"
  local i=0 w p cwd title
  while IFS='|' read -r lw lp _lid lcwd ltitle; do
    i=$((i+1)); [ "$i" = "$n" ] || continue
    w="$lw"; p="$lp"; cwd="$lcwd"; title="$ltitle"; break
  done < <(_t list-panes -a -F '#{window_index}|#{pane_index}|#{pane_id}|#{pane_current_path}|#{pane_title}')
  # tmux-resurrect pane layout: pane <sess> <win> <win_active> <win_flags>
  #   <pane_idx> <title> :<cwd> <pane_active> <cmd> :<full_cmd> [;CLAUDE_SID=..]
  if [ -n "$sid" ]; then
    printf 'pane\twork\t%s\t1\t:*\t%s\t%s\t:%s\t1\t%s\t:%s\t;CLAUDE_SID=%s\n' \
      "$w" "$p" "$title" "$cwd" "$full_cmd" "$full_cmd" "$sid"
  else
    printf 'pane\twork\t%s\t1\t:*\t%s\t%s\t:%s\t1\t%s\t:%s\n' \
      "$w" "$p" "$title" "$cwd" "$full_cmd" "$full_cmd"
  fi
}

_run_restore() {
  TMUX_CMD="tmux -L $SOCKET" RESURRECT_FILE="$RESURRECT_FILE" bash "$RESTORE_SCRIPT"
}

mkdir -p "$TMPROOT" "$RESURRECT_DIR"

# ── Isolation gate ────────────────────────────────────────────────────────────
_fresh_server 1
n_sess="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
if [ "$n_sess" = "1" ]; then
  echo "Isolation: PASS (test server has exactly 1 session)"
else
  echo "Isolation: FAIL — $n_sess sessions; user config leaked in. ABORT."
  exit 1
fi

# ── Test 1: rows with ;CLAUDE_SID resume with that token ─────────────────────
echo "Test 1: snapshot CLAUDE_SID -> resume token"
_fresh_server 2
{ _row_from_live 1 claude session-aaa
  _row_from_live 2 claude session-bbb; } > "$RESURRECT_FILE"
_run_restore
assert_log_has  "pane 1 resumes with session-aaa" "resume=session-aaa"
assert_log_has  "pane 2 resumes with session-bbb" "resume=session-bbb"

# ── Test 2: orphan position sidecars are garbage-collected ───────────────────
echo "Test 2: orphan sidecar files removed"
_fresh_server 1
echo "good"   > "$PANES_DIR/work-1-1.session-id"
echo "orphan" > "$PANES_DIR/oldwork-9-1.session-id"
_row_from_live 1 claude > "$RESURRECT_FILE"
_run_restore
assert_not_exists "orphan sidecar removed" "$PANES_DIR/oldwork-9-1.session-id"

# ── Test 3: claude row with no SID -> bare (no token) ────────────────────────
echo "Test 3: no CLAUDE_SID -> bare command"
_fresh_server 1
_row_from_live 1 claude > "$RESURRECT_FILE"
_run_restore
assert_log_has   "bare write logged"   "bare (no token)"
assert_log_lacks "no resume token"     "resume="

# ── Test 4: non-claude row with no SID is skipped; claude row resumes ────────
echo "Test 4: non-claude pane skipped, claude pane resumed"
_fresh_server 2
{ _row_from_live 1 zsh
  _row_from_live 2 claude session-ccc; } > "$RESURRECT_FILE"
_run_restore
assert_log_has  "claude pane resumed" "resume=session-ccc"
# The zsh row (no SID, full_cmd != claude) must never be written.
assert_log_lacks "zsh pane not written as bare" "zsh"

# ── Test 5: custom claude-cmd qualifies a non-'claude' pane name ─────────────
echo "Test 5: custom @claude-continuity-claude-cmd qualifies the pane"
_fresh_server 1
_t set-option -g @claude-continuity-claude-cmd "myalias"
# full_cmd is 'myalias' (not 'claude') and there is NO SID: the pane qualifies
# ONLY via the claude-cmd match, exercising that fallback. It resumes bare.
_row_from_live 1 myalias > "$RESURRECT_FILE"
_run_restore
assert_log_has "custom-cmd pane written" "bare (no token)"

# ── Results ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════"
echo "  Results: $pass passed, $fail failed"
echo "═══════════════════════════════════"
[ "$fail" -eq 0 ]
