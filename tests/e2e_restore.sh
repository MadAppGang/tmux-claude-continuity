#!/usr/bin/env bash
# e2e_restore.sh — end-to-end test for post_restore.sh
#
# Runs the REAL post_restore.sh script against an isolated tmux socket.
# Uses "echo" as claude_cmd so pane output shows the exact command
# that would be sent (e.g. "echo --resume session-aaa").
#
# SAFETY: Never calls kill-server. Only kills sessions on the test socket.
#
# Usage: bash tests/e2e_restore.sh
# Exit code: 0 = all pass, 1 = failure

set -uo pipefail

SOCKET="tctest$$"
PANES_DIR="/tmp/tctest-panes-$$"
RESURRECT_DIR="/tmp/tctest-resurrect-$$"
RESURRECT_FILE="$RESURRECT_DIR/last"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
RESTORE_SCRIPT="$SCRIPT_DIR/post_restore.sh"
TEST_CMD="echo"

pass=0
fail=0

_cleanup_test_socket() {
  for s in $(tmux -L "$SOCKET" list-sessions -F '#{session_name}' 2>/dev/null); do
    tmux -L "$SOCKET" kill-session -t "$s" 2>/dev/null
  done
}

cleanup() {
  _cleanup_test_socket
  rm -rf "$PANES_DIR" "$RESURRECT_DIR"
}
trap cleanup EXIT

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  PASS: $label"
    ((pass++))
  else
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    got: $(echo "$haystack" | head -3)"
    ((fail++))
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "  PASS: $label"
    ((pass++))
  else
    echo "  FAIL: $label (unexpectedly contains: $needle)"
    ((fail++))
  fi
}

assert_not_exists() {
  local label="$1" path="$2"
  if [ ! -e "$path" ]; then
    echo "  PASS: $label"
    ((pass++))
  else
    echo "  FAIL: $label (file still exists: $path)"
    ((fail++))
  fi
}

_fresh_server() {
  local num_windows="${1:-1}"
  _cleanup_test_socket
  rm -f "$PANES_DIR"/*.session-id 2>/dev/null
  tmux -L "$SOCKET" new-session -d -s work -c /tmp
  local i
  for ((i = 2; i <= num_windows; i++)); do
    tmux -L "$SOCKET" new-window -t work -c /tmp
  done
  tmux -L "$SOCKET" set-option -g @claude-continuity-claude-cmd "$TEST_CMD"
  tmux -L "$SOCKET" set-option -g @claude-continuity-panes-dir "$PANES_DIR"
  tmux -L "$SOCKET" set-option -g @claude-continuity-restore-delay "0"
}

# Run the REAL post_restore.sh, pointed at the test socket and test files
_run_restore() {
  TMUX_CMD="tmux -L $SOCKET" \
  RESURRECT_FILE="$RESURRECT_FILE" \
    bash "$RESTORE_SCRIPT"
}

_capture() {
  tmux -L "$SOCKET" capture-pane -t "$1" -p 2>/dev/null
}

# ── Setup ────────────────────────────────────────────────────────────────────

mkdir -p "$PANES_DIR" "$RESURRECT_DIR"

# ── Test 1: Resume with session IDs ─────────────────────────────────────────

echo "Test 1: Panes with sidecar files get --resume"

_fresh_server 2

echo "session-aaa" > "$PANES_DIR/work-1-1.session-id"
echo "session-bbb" > "$PANES_DIR/work-2-1.session-id"

printf 'pane\twork\t1\t1\t:*\t1\tClaude Code\t/tmp\t1\tclaude\t:claude --dangerously-skip-permissions\n' > "$RESURRECT_FILE"
printf 'pane\twork\t2\t0\t:-\t1\tClaude Code\t/tmp\t1\tclaude\t:claude --dangerously-skip-permissions\n' >> "$RESURRECT_FILE"

_run_restore
sleep 0.5

pane1="$(_capture work:1.1)"
pane2="$(_capture work:2.1)"

assert_contains "pane 1 resumes with session id" "$pane1" "--resume session-aaa"
assert_contains "pane 2 resumes with session id" "$pane2" "--resume session-bbb"

# ── Test 2: Orphan cleanup ──────────────────────────────────────────────────

echo "Test 2: Orphan sidecar files are removed"

_fresh_server 1

echo "good-session" > "$PANES_DIR/work-1-1.session-id"
echo "orphan-session" > "$PANES_DIR/oldwork-9-1.session-id"

printf 'pane\twork\t1\t1\t:*\t1\tClaude Code\t/tmp\t1\tclaude\t:claude\n' > "$RESURRECT_FILE"

_run_restore

assert_not_exists "orphan sidecar removed" "$PANES_DIR/oldwork-9-1.session-id"

# ── Test 3: Missing sidecar → bare command ───────────────────────────────────

echo "Test 3: No sidecar file → bare command (no --resume)"

_fresh_server 1

printf 'pane\twork\t1\t1\t:*\t1\tClaude Code\t/tmp\t1\tclaude\t:claude\n' > "$RESURRECT_FILE"

_run_restore
sleep 0.5

pane_bare="$(_capture work:1.1)"
assert_contains "bare cmd sent" "$pane_bare" "echo"
assert_not_contains "no --resume flag" "$pane_bare" "--resume"

# ── Test 4: Empty sidecar → bare command ─────────────────────────────────────

echo "Test 4: Empty sidecar file → bare command"

_fresh_server 1
> "$PANES_DIR/work-1-1.session-id"

printf 'pane\twork\t1\t1\t:*\t1\tClaude Code\t/tmp\t1\tclaude\t:claude\n' > "$RESURRECT_FILE"

_run_restore
sleep 0.5

pane_empty="$(_capture work:1.1)"
assert_not_contains "empty sidecar → no --resume" "$pane_empty" "--resume"

# ── Test 5: Non-claude panes are skipped ─────────────────────────────────────

echo "Test 5: Non-claude panes are not touched"

_fresh_server 2

printf 'pane\twork\t1\t1\t:*\t1\tshell\t/tmp\t1\tzsh\t:zsh\n' > "$RESURRECT_FILE"
printf 'pane\twork\t2\t0\t:-\t1\tClaude Code\t/tmp\t1\tclaude\t:claude\n' >> "$RESURRECT_FILE"

echo "session-ccc" > "$PANES_DIR/work-2-1.session-id"

_run_restore
sleep 0.5

pane_zsh="$(_capture work:1.1)"
pane_claude="$(_capture work:2.1)"

assert_not_contains "zsh pane not touched (no --resume)" "$pane_zsh" "--resume"
assert_not_contains "zsh pane not touched (no echo)" "$pane_zsh" "$ echo"
assert_contains "claude pane resumed" "$pane_claude" "--resume session-ccc"

# ── Test 6: Custom alias detection ───────────────────────────────────────────

echo "Test 6: Pane with custom alias (not 'claude') is detected"

_fresh_server 1
tmux -L "$SOCKET" set-option -g @claude-continuity-claude-cmd "myalias"

echo "session-ddd" > "$PANES_DIR/work-1-1.session-id"

printf 'pane\twork\t1\t1\t:*\t1\tClaude Code\t/tmp\t1\tmyalias\t:myalias\n' > "$RESURRECT_FILE"

_run_restore
sleep 0.5

pane_alias="$(_capture work:1.1)"
assert_contains "custom alias with --resume" "$pane_alias" "myalias --resume session-ddd"

# ── Test 7: Two-line sidecar (UUID + title) uses UUID ────────────────────────

echo "Test 7: Two-line sidecar uses UUID from line 1, not title from line 2"

_fresh_server 1
tmux -L "$SOCKET" set-option -g @claude-continuity-claude-cmd "$TEST_CMD"

printf '%s\n%s\n' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "my-custom-title" \
  > "$PANES_DIR/work-1-1.session-id"

printf 'pane\twork\t1\t1\t:*\t1\tClaude Code\t/tmp\t1\tclaude\t:claude\n' > "$RESURRECT_FILE"

_run_restore
sleep 0.5

pane_titled="$(_capture work:1.1)"
assert_contains "uses UUID from line 1" "$pane_titled" "--resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
assert_not_contains "does not use title" "$pane_titled" "my-custom-title"

# ── Test 8: Legacy single-line title sidecar still works ─────────────────────

echo "Test 8: Legacy sidecar with title (no UUID) falls back to title as search term"

_fresh_server 1

echo "bugfix-sentry" > "$PANES_DIR/work-1-1.session-id"

printf 'pane\twork\t1\t1\t:*\t1\tClaude Code\t/tmp\t1\tclaude\t:claude\n' > "$RESURRECT_FILE"

_run_restore
sleep 0.5

pane_legacy="$(_capture work:1.1)"
assert_contains "legacy title used as search term" "$pane_legacy" "--resume bugfix-sentry"

# ── Results ──────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════"
echo "  Results: $pass passed, $fail failed"
echo "═══════════════════════════════════"

[ "$fail" -eq 0 ]
