#!/usr/bin/env bash
# wrapper_depth_enrich.sh — regression test for pre_save.sh SID enrichment when
# Claude runs behind a WRAPPER.
#
# The bug: pre_save.sh looked for the by-pid sidecar only on pane_pid and its
# DIRECT children. The common launcher alias
#
#     c → op run --environment … -- claude --dangerously-skip-permissions
#
# puts 1Password's `op` in between, so the real tree is
#     zsh (pane_pid) → op run → claude
# and Claude is a GRANDchild. SOURCE 1 therefore matched nothing, leaving only
# the cmdline scrape — which fires exclusively for sessions that ALREADY carry
# `--resume <uuid>`. Every FRESH session (typed `c`, or `c --worktree foo`) was
# saved with no CLAUDE_SID and came back from the next restore as a brand-new
# empty session. Measured on a real machine: 0 of 46 panes matched via SOURCE 1,
# and 17 of 44 restored panes were relaunched bare, losing their history.
#
# Fully isolated: own tmux socket with `-f /dev/null` (no user config, so the
# boot auto-restore never fires) and own panes dir. pre_save.sh calls bare
# `tmux`, so a PATH shim redirects it to the test socket.
#
# Usage: bash tests/wrapper_depth_enrich.sh   (exit 0 = pass)

set -uo pipefail

SOCKET="ccwd$$"
TD="/tmp/ccwd-$$"
PD="$TD/panes"
LD="$TD/launch"
BIN="$TD/bin"
RD="$TD/resurrect"
SNAP="$TD/snapshot.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
PRE_SAVE="$SCRIPT_DIR/pre_save.sh"

# THIS TEST WAS WRITING INTO THE USER'S LIVE RESURRECT DIRECTORY.
# It invokes pre_save.sh six times; pre_save triggers a resurrect save, and
# resurrect resolves its output dir from @resurrect-dir on the server it is
# talking to — here, via the PATH shim below, the TEST server. That option was
# never set, so every run saved into ~/.local/share/tmux/resurrect. See
# tests/lib/resurrect_guard.sh for the measured damage. Redirecting the RESTORE
# side is not enough: RESURRECT_FILE covers reads, @resurrect-dir covers writes.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing — refusing to run a save-side test unguarded"
  exit 1
}
cc_register_test_session work

pass=0
fail=0

_tmux() { tmux -L "$SOCKET" -f /dev/null "$@"; }

_teardown() {
  tmux -L "$SOCKET" kill-server 2>/dev/null
  rm -rf "$TD"
  cc_warn_on_resurrect_leak
}
trap _teardown EXIT INT TERM

mkdir -p "$PD/by-pid" "$LD" "$BIN" "$RD"

ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; [ $# -gt 1 ] && echo "    $2"; fail=$((fail+1)); }

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "got '$got', want '$want'"; fi
}

# pre_save.sh invokes bare `tmux`. Shim it onto the test socket so the real
# server (and the user's live sessions) are never touched.
cat > "$BIN/tmux" <<EOF
#!/usr/bin/env bash
exec $(command -v tmux) -L "$SOCKET" -f /dev/null "\$@"
EOF
chmod +x "$BIN/tmux"

# ── Build a pane whose leaf process is a GRANDCHILD of pane_pid ──────────────
# The trailing `:` in each -c string defeats sh's exec optimization (a single
# command would otherwise replace the shell, collapsing the tree we need).
_tmux new-session -d -s work "sh -c 'sh -c \"sleep 600; :\"; :'"
_tmux set-option -g @claude-continuity-panes-dir "$PD" >/dev/null
_tmux set-option -g @claude-continuity-launch-dir "$LD" >/dev/null
# The save side. Set on the SERVER, because that is where resurrect reads it.
_tmux set-option -g @resurrect-dir "$RD" >/dev/null
# Pre-flight: ask the server what it will actually use, and refuse to run if the
# answer is the user's real directory. A test that CAN write there should abort,
# not hope.
cc_guard_resurrect_dir "$RD" tmux -L "$SOCKET" -f /dev/null

for _ in 1 2 3 4 5 6 7 8 9 10; do
  PANE_PID="$(_tmux list-panes -t work -F '#{pane_pid}' 2>/dev/null | head -1)"
  [ -n "${PANE_PID:-}" ] && [ -n "$(pgrep -P "$PANE_PID" 2>/dev/null)" ] && break
  sleep 0.3
done

CHILD="$(pgrep -P "$PANE_PID" 2>/dev/null | head -1)"
GRANDCHILD="$(pgrep -P "${CHILD:-0}" 2>/dev/null | head -1)"

echo "[0] PREMISE: the test tree really is pane_pid -> child -> grandchild"
if [ -n "$PANE_PID" ] && [ -n "$CHILD" ] && [ -n "$GRANDCHILD" ]; then
  ok "built a depth-2 tree ($PANE_PID -> $CHILD -> $GRANDCHILD)"
else
  bad "could not build a depth-2 process tree" "pane=$PANE_PID child=$CHILD grand=$GRANDCHILD"
  echo "  RESULT: $pass passed, $fail failed"; exit 1
fi

# Coordinates come from the live server: pre_save.sh keys its map on the real
# "<session>:<window>.<pane>", so a hardcoded index silently matches nothing.
COORDS="$(_tmux list-panes -a -F '#S	#I	#P' | head -1)"
SESS="$(printf '%s' "$COORDS" | cut -f1)"
WIN="$(printf '%s' "$COORDS" | cut -f2)"
PIDX="$(printf '%s' "$COORDS" | cut -f3)"

write_snapshot() {
  printf 'pane\t%s\t%s\t1\t:*\t%s\t\xe2\x9c\xb3 Claude Code\t:%s\t1\tsh\t:sh -c sleep 600\n' \
    "$SESS" "$WIN" "$PIDX" "$TD" > "$SNAP"
}

sid_in_snapshot() {
  awk -F'\t' '$1=="pane"{for(i=1;i<=NF;i++) if($i ~ /^;CLAUDE_SID=/) print substr($i,13)}' "$SNAP" | head -1
}

# ── 1. THE REGRESSION: sidecar on the grandchild must be found ───────────────
echo "[1] GRANDCHILD (the op-run case): SID must reach the snapshot"
SID_GRAND="11111111-1111-4111-8111-111111111111"
echo "$SID_GRAND" > "$PD/by-pid/$GRANDCHILD.session-id"
write_snapshot
PATH="$BIN:$PATH" bash "$PRE_SAVE" "$SNAP"
assert_eq "grandchild SID embedded in snapshot" "$(sid_in_snapshot)" "$SID_GRAND"

# ── 2. Depth-1 and depth-0 must keep working (what the old code covered) ─────
echo "[2] DIRECT CHILD still works (plain 'claude' at a prompt)"
rm -f "$PD/by-pid/"*.session-id
SID_CHILD="22222222-2222-4222-8222-222222222222"
echo "$SID_CHILD" > "$PD/by-pid/$CHILD.session-id"
write_snapshot
PATH="$BIN:$PATH" bash "$PRE_SAVE" "$SNAP"
assert_eq "direct-child SID embedded" "$(sid_in_snapshot)" "$SID_CHILD"

echo "[3] PANE PROCESS ITSELF still works (exec'd claude)"
rm -f "$PD/by-pid/"*.session-id
SID_PANE="33333333-3333-4333-8333-333333333333"
echo "$SID_PANE" > "$PD/by-pid/$PANE_PID.session-id"
write_snapshot
PATH="$BIN:$PATH" bash "$PRE_SAVE" "$SNAP"
assert_eq "pane-process SID embedded" "$(sid_in_snapshot)" "$SID_PANE"

# ── 4. Shallowest wins ───────────────────────────────────────────────────────
# A nested Claude (one an agent spawned through its Bash tool, several levels
# down) registers its own sidecar. It must not shadow the pane's own session.
echo "[4] TIE-BREAK: the shallowest process owns the pane"
rm -f "$PD/by-pid/"*.session-id
echo "$SID_CHILD" > "$PD/by-pid/$CHILD.session-id"
echo "$SID_GRAND" > "$PD/by-pid/$GRANDCHILD.session-id"
write_snapshot
PATH="$BIN:$PATH" bash "$PRE_SAVE" "$SNAP"
assert_eq "shallower (child) SID wins over deeper (grandchild)" "$(sid_in_snapshot)" "$SID_CHILD"

# ── 4b. The typed-command capture must survive alongside the SID ─────────────
# ;CLAUDE_CMD carries the command as the user actually typed it (1b4e32a). It is
# a separate snapshot field from ;CLAUDE_SID and rides the same sidmap row, so a
# change to the SID lookup can silently drop it — which would restore every pane
# as the configured default instead of its own launcher.
echo "[4b] TYPED COMMAND: ;CLAUDE_CMD rides along with ;CLAUDE_SID"
rm -f "$PD/by-pid/"*.session-id
echo "$SID_GRAND" > "$PD/by-pid/$GRANDCHILD.session-id"
PANE_ID="$(_tmux list-panes -a -F '#{pane_id}' | head -1)"
printf 'c --worktree qr --name "My Session"\n' > "$LD/${PANE_ID#%}"
write_snapshot
PATH="$BIN:$PATH" bash "$PRE_SAVE" "$SNAP"
CMD_B64="$(awk -F'\t' '$1=="pane"{for(i=1;i<=NF;i++) if($i ~ /^;CLAUDE_CMD=/) print substr($i,13)}' "$SNAP" | head -1)"
assert_eq "typed command embedded and decodes verbatim" \
  "$(printf '%s' "$CMD_B64" | base64 -d 2>/dev/null || printf '%s' "$CMD_B64" | base64 -D 2>/dev/null)" \
  'c --worktree qr --name "My Session"'
assert_eq "SID still embedded alongside it" "$(sid_in_snapshot)" "$SID_GRAND"
rm -f "$LD/${PANE_ID#%}"

# ── 4c. One session id must never be recorded for two panes ──────────────────
# An old restore could route one snapshot row into two panes, leaving both
# running `claude --resume <same uuid>`. Both then register that id, both rows
# carry it, and the next restore recreates the pair — while two Claude instances
# append to a single transcript. The save must keep exactly one, stably.
echo "[4c] ONE SESSION, ONE PANE: a duplicate id is dropped from the extra pane"
rm -f "$PD/by-pid/"*.session-id
SECOND="$(_tmux split-window -t work -d -P -F '#{pane_id}' "sh -c 'sh -c \"sleep 600; :\"; :'")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  SEC_PID="$(_tmux display-message -p -t "$SECOND" '#{pane_pid}')"
  SEC_CHILD="$(pgrep -P "${SEC_PID:-0}" 2>/dev/null | head -1)"
  [ -n "$SEC_CHILD" ] && break
  sleep 0.3
done
if [ -n "$SEC_CHILD" ]; then ok "second pane's process resolved ($SECOND -> $SEC_CHILD)"
else bad "second pane's process resolved" "SEC_PID=$SEC_PID SEC_CHILD=empty — the duplicate would never exist"; fi
SID_DUP="55555555-5555-4555-8555-555555555555"
echo "$SID_DUP" > "$PD/by-pid/$GRANDCHILD.session-id"
echo "$SID_DUP" > "$PD/by-pid/$SEC_CHILD.session-id"

COORDS2="$(_tmux list-panes -a -F '#S	#I	#P	#{pane_id}' | grep "	${SECOND}$" | head -1)"
S2="$(printf '%s' "$COORDS2" | cut -f1)"; W2="$(printf '%s' "$COORDS2" | cut -f2)"
P2="$(printf '%s' "$COORDS2" | cut -f3)"
{ printf 'pane\t%s\t%s\t1\t:*\t%s\t\xe2\x9c\xb3 Claude Code\t:%s\t1\tsh\t:sh\n' "$SESS" "$WIN" "$PIDX" "$TD"
  printf 'pane\t%s\t%s\t1\t:*\t%s\t\xe2\x9c\xb3 Claude Code\t:%s\t1\tsh\t:sh\n' "$S2" "$W2" "$P2" "$TD"
} > "$SNAP"
CC_SAVE_LOG="$TD/save.log" PATH="$BIN:$PATH" bash "$PRE_SAVE" "$SNAP"
assert_eq "the id is recorded exactly once across both panes" \
  "$(grep -o ";CLAUDE_SID=$SID_DUP" "$SNAP" | wc -l | tr -d ' ')" "1"

# The drop must be visible. Afterwards the row simply looks like a pane that was
# never Claude, so without a log line there is nothing to explain the missing
# session to whoever goes looking for it.
if grep -q "DUP-SESSION" "$TD/save.log" 2>/dev/null; then
  ok "the dropped pane is logged"
else
  bad "the dropped pane is logged" "no DUP-SESSION line in $TD/save.log"
fi

# Stability matters as much as uniqueness: if the winner flipped between saves the
# pair would ping-pong, each restore handing the session to the other pane.
FIRST_WINNER="$(awk -F'\t' '$1=="pane"{for(i=1;i<=NF;i++) if($i ~ /^;CLAUDE_SID=/) print $2":"$3"."$6}' "$SNAP")"
CC_SAVE_LOG="$TD/save.log" PATH="$BIN:$PATH" bash "$PRE_SAVE" "$SNAP"
assert_eq "same pane keeps it on a second save (no ping-pong)" \
  "$(awk -F'\t' '$1=="pane"{for(i=1;i<=NF;i++) if($i ~ /^;CLAUDE_SID=/) print $2":"$3"."$6}' "$SNAP")" \
  "$FIRST_WINNER"
assert_eq "no non-uuid token was embedded (the ;DUP= marker never leaks)" \
  "$(grep -o ';CLAUDE_SID=[^\t]*' "$SNAP" | grep -cv ';CLAUDE_SID=[0-9a-f-]\{36\}$' | tr -d ' ')" "0"
_tmux kill-pane -t "$SECOND" 2>/dev/null
rm -f "$PD/by-pid/"*.session-id

# ── 5. A process belonging to no pane must never be attributed ───────────────
echo "[5] NO FALSE ATTRIBUTION: an unrelated process claims nothing"
write_snapshot
rm -f "$PD/by-pid/"*.session-id
echo "44444444-4444-4444-8444-444444444444" > "$PD/by-pid/$$.session-id"
write_snapshot
PATH="$BIN:$PATH" bash "$PRE_SAVE" "$SNAP"
assert_eq "no SID embedded for a non-pane process" "$(sid_in_snapshot)" ""

# ── The save side actually stayed inside the sandbox ─────────────────────────
echo "[6] ISOLATION: six saves, none of them in the user's real resurrect dir"
if cc_assert_no_resurrect_leak; then
  ok "no snapshot naming this test's sessions reached $CC_REAL_RESURRECT"
else
  bad "a snapshot naming this test's sessions reached the user's real resurrect dir" \
      "see the LEAKED list above"
fi
# The leak check is only worth having if it CAN fail — prove the detector fires
# on a planted fixture before believing it when it says "clean".
if cc_selftest_leak_detector "$TD"; then
  ok "the leak detector fires on a planted snapshot (the check above is not vacuous)"
else
  bad "the leak detector fires on a planted snapshot" \
      "it found nothing in a directory that definitely contains a 'work' snapshot"
fi
# ...and the redirect is still in force at the end, so any save this test may
# have triggered asynchronously could only have landed inside the sandbox.
assert_eq "the server still reports the redirected @resurrect-dir" \
  "$(_tmux show-options -gv @resurrect-dir 2>/dev/null)" "$RD"

echo "=================================================================="
echo "  RESULT: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
