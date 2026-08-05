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
SNAP="$TD/snapshot.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
PRE_SAVE="$SCRIPT_DIR/pre_save.sh"

pass=0
fail=0

_tmux() { tmux -L "$SOCKET" -f /dev/null "$@"; }

_teardown() {
  tmux -L "$SOCKET" kill-server 2>/dev/null
  rm -rf "$TD"
}
trap _teardown EXIT

mkdir -p "$PD/by-pid" "$LD" "$BIN"

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

# ── 5. A process belonging to no pane must never be attributed ───────────────
echo "[5] NO FALSE ATTRIBUTION: an unrelated process claims nothing"
rm -f "$PD/by-pid/"*.session-id
echo "44444444-4444-4444-8444-444444444444" > "$PD/by-pid/$$.session-id"
write_snapshot
PATH="$BIN:$PATH" bash "$PRE_SAVE" "$SNAP"
assert_eq "no SID embedded for a non-pane process" "$(sid_in_snapshot)" ""

echo "=================================================================="
echo "  RESULT: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
