#!/usr/bin/env bash
# list_tree_contract.sh — `cc_popup.sh --list` is the black-box inventory surface,
# and its stdout is a CONTRACT. Under the pane atom it became a TREE: one row per
# node, session -> window -> pane, depth-first, 18 TAB-separated columns.
#
# What is asserted here (the contract, not any implementation of it):
#   [1] SHAPE      18 columns on every row, NO field ever empty (FR6.2/L1: TAB is
#                  IFS whitespace, so one empty column vanishes and shifts every
#                  column after it), and the level column is one of three words.
#   [2] SIGIL      the node column carries $N / @N / %N / !KEY and "the sigil IS
#                  the level" — a consumer must be able to tell a session row from
#                  a window row from a pane row without counting.
#   [3] TREE       every parent link resolves to a node that is itself a row and
#                  appears EARLIER (depth-first, parents first); only session rows
#                  are parentless; the row set matches the live server exactly.
#   [4] AGGREGATE  a container's state is AWAKE (no pane frozen) / FROZEN (every
#                  pane frozen) / PARTIAL (some), and its pane_count, frozen_panes
#                  and sid_count are the sums over its own panes. Recomputed from
#                  the pane rows and compared — not spot-checked.
#   [5] PROJECTION `--list --level window` reproduces the pre-tree row set: exactly
#                  one row per LIVE window, columns 1-10 unchanged. This is the
#                  one-word fix for any consumer written against the flat contract,
#                  so it has to be exact, or `doctor` silently trebles its counts.
#
# The aggregate is re-asserted after each of three freezes — one pane of three,
# then the rest of that window, then the rest of the session — because AWAKE ->
# PARTIAL -> FROZEN is precisely the transition the window model could not express.
#
# THE FIXTURE RULE: every pane that must be freezable is a BARE INTERACTIVE SHELL
# (a shell carrying an operand is SHELL-WITH-WORK => UNSAFE, §H4). One fake Claude
# tree — pane -> shell -> op(wrapper) -> claude, claude a GRANDCHILD — is grown so
# that the sid_count aggregation is not vacuously 0 everywhere. Its leaf blocks on
# a writer-less FIFO: `sleep` is UNSAFE by H4's last row, and a FIFO read forks no
# child and churns no pid.
#
# Isolation: own tmux socket, `-f /dev/null` on EVERY tmux invocation, all state
# under /tmp, CC_TEST=1.
#
# Usage: bash tests/list_tree_contract.sh   (exit 0 = pass)

set -uo pipefail

# ── RESURRECT SAVE-SIDE ISOLATION ────────────────────────────────────────────
# RESURRECT_FILE redirects resurrect READS. Only @resurrect-dir redirects its
# WRITES. A test that triggers a save without setting it deposits fixture
# snapshots in the user's live resurrect directory and can leave `last`
# pointing at one. See tests/lib/resurrect_guard.sh for the measured damage.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed work legacy alpha beta lvl cA cB cC cD cE

SOCKET="cclt$$"
TD="/tmp/cclt-$$"
FD="$TD/frozen"
PD="$TD/panes"
LD="$TD/launch"
QD="$TD/pending"
RD="$TD/resurrect"
BIN="$TD/bin"
FIX="$TD/fix"
LOG="$TD/cc.log"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
FREEZE="$SCRIPT_DIR/cc_freeze.sh"
POPUP="$SCRIPT_DIR/cc_popup.sh"

TMUX_CMD_STR="tmux -L $SOCKET -f /dev/null"
NOW="$(date +%s)"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
no()  { echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail+1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$2], want [$3]"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else no "$1" "got [$2], want anything else"; fi; }
assert_empty() { # <name> <multi-line violation report>
  if [ -z "$2" ]; then ok "$1"; else no "$1" "$(printf '%s' "$2" | head -6 | tr '\n' '/')"; fi
}

# ── PRE-FLIGHT GUARD ─────────────────────────────────────────────────────────
case "$SOCKET" in
  default|""|*/*|*\ *) echo "ABORT: unsafe socket name [$SOCKET]"; exit 1 ;;
  cclt*) ;;
  *) echo "ABORT: [$SOCKET] is not this test's socket"; exit 1 ;;
esac
case "$TMUX_CMD_STR" in *"-L $SOCKET"*) ;; *) echo "ABORT: TMUX_CMD not on the test socket"; exit 1 ;; esac
case "$TMUX_CMD_STR" in *"-f /dev/null"*) ;; *) echo "ABORT: TMUX_CMD lacks -f /dev/null"; exit 1 ;; esac
case "$TD" in /tmp/*) ;; *) echo "ABORT: temp root [$TD] is not under /tmp"; exit 1 ;; esac
for d in "$FD" "$PD" "$QD" "$RD"; do
  case "$d" in "$HOME"/*) echo "ABORT: [$d] is inside \$HOME"; exit 1 ;; esac
done
if tmux -L "$SOCKET" -f /dev/null list-sessions >/dev/null 2>&1; then
  echo "ABORT: socket $SOCKET already has a live server"; exit 1
fi

_t() { tmux -L "$SOCKET" -f /dev/null "$@"; }
_kill_fixtures() {
  ps -axo pid=,command= > "$TD/ps.exit" 2>/dev/null || return 0
  while read -r _p _rest; do
    [ -z "${_p:-}" ] && continue
    [ "$_p" = "$$" ] && continue
    case "$_rest" in *"$TD"*) kill -9 "$_p" 2>/dev/null ;; esac
  done < "$TD/ps.exit"
}
_teardown() { _t kill-server 2>/dev/null; _kill_fixtures; rm -rf "$TD"; }
# Re-wrap the teardown so a leak into the real resurrect dir fails the run
# even on the early-abort paths that never reach the final assertions.
_cc_teardown_guarded() { _teardown; cc_warn_on_resurrect_leak || exit 1; }
trap _cc_teardown_guarded EXIT INT TERM

mkdir -p "$FD" "$PD/by-pid" "$LD" "$QD" "$RD" "$BIN" "$FIX"

MISSING=""
[ -f "$FREEZE" ] || MISSING="$MISSING $FREEZE"
[ -f "$POPUP" ]  || MISSING="$MISSING $POPUP"
if [ -n "$MISSING" ]; then
  echo "  FAIL: required script(s) missing:$MISSING"
  echo ""; echo "  Results: 0 passed, 1 failed"; exit 1
fi

ln -s /bin/sh "$BIN/op"
ln -s /bin/sh "$BIN/claude"
mkfifo "$FIX/hold.fifo"
printf 'read _x < "%s/hold.fifo"\n' "$FIX" > "$FIX/hold.sh"
printf '"%s/claude" "%s/hold.sh"\n:\n' "$BIN" "$FIX" > "$FIX/oprun.sh"
CLAUDE_TREE_CMD="\"$BIN/op\" \"$FIX/oprun.sh\""

_t new-session -d -s _seed -c /tmp
_t set-option -g base-index 1 >/dev/null
_t set-option -g pane-base-index 1 >/dev/null
_t set-option -g default-shell /bin/sh >/dev/null
_t set-option -g default-command "sh -i" >/dev/null
_t set-environment -g ENV /dev/null >/dev/null
_t set-option -g @claude-continuity-panes-dir    "$PD" >/dev/null
_t set-option -g @claude-continuity-launch-dir   "$LD" >/dev/null
_t set-option -g @claude-continuity-pending-dir  "$QD" >/dev/null
_t set-option -g @claude-continuity-log-file     "$LOG" >/dev/null
_t set-option -g @claude-continuity-claude-cmd   "echo" >/dev/null
_t set-option -g @claude-continuity-claudish-cmd "claudish" >/dev/null
_t set-option -g @claude-continuity-freeze-dir   "$FD" >/dev/null
_t set-option -g @resurrect-dir                  "$RD" >/dev/null
# Pre-flight: ask the SERVER what it will actually use and refuse to run if
# the answer is the user's real directory. A set-option that ran too early or
# at the wrong scope leaves the default in place, and only asking catches it.
cc_guard_resurrect_dir "$RD" tmux -L "$SOCKET" -f /dev/null

# alpha:1 three (3 panes) · alpha:2 two (2 panes) · beta:1 solo (1 pane)
# 2 sessions / 3 windows / 6 panes. A window name carrying a TAB is not created
# here: the contract says free text is SANITISED, and a tab that never exists
# cannot prove sanitisation — that is a fuzzing job, not a contract assertion.
_t new-session -d -s alpha -n three -c /tmp
_t split-window -t alpha:1 -c /tmp
_t split-window -t alpha:1 -c /tmp
_t new-window  -t alpha:2 -n two -c /tmp
_t split-window -t alpha:2 -c /tmp
_t new-session -d -s beta -n solo -c /tmp
_t kill-session -t _seed

NS="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NS" != "2" ]; then echo "ABORT: expected 2 sessions on the test socket, found $NS"; exit 1; fi

_pane_id_at() { _t list-panes -t "$1" -F '#{pane_index} #{pane_id}' 2>/dev/null \
                  | awk -v i="$2" '$1==i { print $2; exit }'; }
_claude_procs() { ps -axo pid=,command= \
    | awk -v b="$BIN" -v s="/claude " 'index($0, b s) { n++ } END { print n+0 }'; }
_descendants() {
  ps -axo pid=,ppid= | awk -v r="$1" '
    { pid[NR]=$1; pp[$1]=$2; n=NR }
    END { q[1]=r; c=1; h=1
          while (h <= c) { cur=q[h]; h++
            for (i=1; i<=n; i++) if (pp[pid[i]] == cur) { c++; q[c]=pid[i] } }
          for (i=2; i<=c; i++) print q[i] }'
}
A1="$(_pane_id_at alpha:1 1)"
A2="$(_pane_id_at alpha:1 2)"
A3="$(_pane_id_at alpha:1 3)"
for _try in 1 2 3 4 5 6 7 8 9 10 11 12; do
  [ "$(_claude_procs)" -ge 1 ] && break
  case "$_try" in 1|5|9) _t send-keys -t "$A1" "$CLAUDE_TREE_CMD" Enter ;; esac
  sleep 0.4
done
SID_A="99999999-cccc-4ccc-8ccc-999999999999"
CLAUDE_PID=""
for p in $(_descendants "$(_t display-message -p -t "$A1" '#{pane_pid}')"); do
  case "$(ps -p "$p" -o command= 2>/dev/null)" in "$BIN/claude"*) CLAUDE_PID="$p"; break ;; esac
done
[ -n "$CLAUDE_PID" ] && echo "$SID_A" > "$PD/by-pid/$CLAUDE_PID.session-id"

_list() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" bash "$POPUP" --list "$@"
}
_freeze() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_NO_SAVE=1 CC_NO_NUDGE=1 bash "$FREEZE" "$@"
}
_live_windows() { _t list-windows -a -F '#{window_id}' | sort; }
_live_panes()   { _t list-panes -a -F '#{pane_id}' | sort; }
_live_sessions(){ _t list-sessions -F '#{session_id}' | sort; }
_rowcount()     { printf '%s\n' "$1" | grep -c . | tr -d ' '; }
_at_level()     { printf '%s\n' "$1" | awk -F'\t' -v l="$2" '$11==l'; }

# ── The contract checks, each returning a (possibly empty) violation report ──
_check_shape() { printf '%s\n' "$1" | awk -F'\t' '
  NF != 18 { printf "row %d has %d columns, not 18: %s\n", NR, NF, substr($0,1,90) }
  { for (i=1; i<=NF; i++) if ($i == "") printf "row %d column %d is EMPTY\n", NR, i }
  $11 != "session" && $11 != "window" && $11 != "pane" {
      printf "row %d level column is [%s]\n", NR, $11 }
  /^\t/  { printf "row %d starts with a TAB\n", NR }
  /\t\t/ { printf "row %d contains an empty TAB-separated field\n", NR }
  /\t$/  { printf "row %d ends with a TAB\n", NR }'
}
_check_sigil() { printf '%s\n' "$1" | awk -F'\t' '
  { s = substr($13, 1, 1); l = $11
    want = (s == "$") ? "session" : (s == "@") ? "window" : (s == "%" || s == "!") ? "pane" : "?"
    if (want == "?")  printf "row %d node [%s] carries no known sigil\n", NR, $13
    else if (want != l) printf "row %d node [%s] sigil says %s, level column says %s\n", NR, $13, want, l }'
}
_check_tree() { printf '%s\n' "$1" | awk -F'\t' '
  { n++; lev[n]=$11; par[n]=$12; nod[n]=$13
    if (!(($13) in first)) first[$13] = n
    else printf "node [%s] appears on more than one row\n", $13 }
  END { for (i=1; i<=n; i++) {
          if (lev[i] == "session") {
            if (par[i] != "-") printf "session row [%s] has a parent [%s]\n", nod[i], par[i]
            continue }
          if (par[i] == "-") { printf "%s row [%s] is parentless\n", lev[i], nod[i]; continue }
          if (!((par[i]) in first)) { printf "row [%s] parent [%s] resolves to no row\n", nod[i], par[i]; continue }
          if (first[par[i]] > i) printf "row [%s] appears before its parent [%s] (not depth-first)\n", nod[i], par[i]
        } }'
}
# The aggregate, recomputed from the pane rows alone.
_check_aggregate() { printf '%s\n' "$1" | awk -F'\t' '
  { n++; st[n]=$1; pc[n]=$7; sc[n]=$8; lev[n]=$11; par[n]=$12; nod[n]=$13; fp[n]=$14
    if ($11 == "pane") {
      if ($7 != 1)  printf "pane row [%s] has pane_count %s, want 1\n", $13, $7
      if ($14 != 0 && $14 != 1) printf "pane row [%s] has frozen_panes %s, want 0 or 1\n", $13, $14
      if ($1 == "AWAKE" && $14 != 0) printf "pane row [%s] is AWAKE but frozen_panes=%s\n", $13, $14
      if ($1 != "AWAKE" && $14 != 1) printf "pane row [%s] is %s but frozen_panes=%s\n", $13, $1, $14
      wtot[$12]++; wfroz[$12] += $14; wsid[$12] += $8 } }
  END {
    for (i = 1; i <= n; i++) if (lev[i] == "window") {
      t = wtot[nod[i]] + 0; f = wfroz[nod[i]] + 0; s = wsid[nod[i]] + 0
      if (pc[i] + 0 != t) printf "window [%s] pane_count=%s but it has %d pane rows\n", nod[i], pc[i], t
      if (fp[i] + 0 != f) printf "window [%s] frozen_panes=%s but its panes sum to %d\n", nod[i], fp[i], f
      if (sc[i] + 0 != s) printf "window [%s] sid_count=%s but its panes sum to %d\n", nod[i], sc[i], s
      want = (f == 0) ? "AWAKE" : (f == t) ? "FROZEN" : "PARTIAL"
      if (st[i] != want) printf "window [%s] state=%s but %d/%d panes frozen => %s\n", nod[i], st[i], f, t, want
      stot[par[i]] += t; sfroz[par[i]] += f; ssid[par[i]] += s }
    for (i = 1; i <= n; i++) if (lev[i] == "session") {
      t = stot[nod[i]] + 0; f = sfroz[nod[i]] + 0; s = ssid[nod[i]] + 0
      if (pc[i] + 0 != t) printf "session [%s] pane_count=%s but its windows hold %d panes\n", nod[i], pc[i], t
      if (fp[i] + 0 != f) printf "session [%s] frozen_panes=%s but its windows sum to %d\n", nod[i], fp[i], f
      if (sc[i] + 0 != s) printf "session [%s] sid_count=%s but its windows sum to %d\n", nod[i], sc[i], s
      want = (f == 0) ? "AWAKE" : (f == t) ? "FROZEN" : "PARTIAL"
      if (st[i] != want) printf "session [%s] state=%s but %d/%d panes frozen => %s\n", nod[i], st[i], f, t, want } }'
}
_state_of() { # <list> <node> -> the state column of that node's row
  printf '%s\n' "$1" | awk -F'\t' -v nd="$2" '$13==nd { print $1; exit }'
}
_frac_of() { # <list> <node> -> "frozen/total" for a container
  printf '%s\n' "$1" | awk -F'\t' -v nd="$2" '$13==nd { print $14 "/" $7; exit }'
}
_assert_row_invariants() { # <label> <list> — true of ANY projection
  assert_empty "$1: every row is 18 non-empty TAB-separated columns" "$(_check_shape "$2")"
  assert_empty "$1: the node sigil agrees with the level column"     "$(_check_sigil "$2")"
}
_assert_tree_invariants() { # <label> <list> — only meaningful on the FULL tree:
  # a single-level projection has no parent rows to resolve to and no pane rows
  # to aggregate from, so running these over one would assert a contradiction.
  _assert_row_invariants "$1" "$2"
  assert_empty "$1: every parent resolves, parents first, no node twice" "$(_check_tree "$2")"
  assert_empty "$1: container aggregates match their panes"          "$(_check_aggregate "$2")"
}

# ── [1] The awake tree ───────────────────────────────────────────────────────
echo "[1] The tree contract on an all-awake server (2 sessions / 3 windows / 6 panes)"
LIST="$(_list 2>"$TD/e1")"; RC=$?
printf '%s\n' "$LIST" | sed 's/^/    /'
[ -s "$TD/e1" ] && printf '    stderr: %s\n' "$(head -3 "$TD/e1")"
assert_eq "--list exits 0" "$RC" "0"
_assert_tree_invariants "shape" "$LIST"

assert_eq "one row per live session" \
  "$(_at_level "$LIST" session | awk -F'\t' '{print $13}' | sort | tr '\n' ' ')" \
  "$(_live_sessions | tr '\n' ' ')"
assert_eq "one row per live window" \
  "$(_at_level "$LIST" window | awk -F'\t' '{print $13}' | sort | tr '\n' ' ')" \
  "$(_live_windows | tr '\n' ' ')"
assert_eq "one row per live pane" \
  "$(_at_level "$LIST" pane | awk -F'\t' '{print $13}' | sort | tr '\n' ' ')" \
  "$(_live_panes | tr '\n' ' ')"
assert_eq "the tree is 2 + 3 + 6 rows" "$(_rowcount "$LIST")" "11"
assert_eq "a pane row's window_id column names its parent window" \
  "$(_at_level "$LIST" pane | awk -F'\t' '$10 != $12' | grep -c . | tr -d ' ')" "0"
assert_eq "a session row has no window_index and no window_id" \
  "$(_at_level "$LIST" session | awk -F'\t' '$3 != "-" || $4 != "-" || $10 != "-"' | grep -c . | tr -d ' ')" "0"
assert_eq "no container row carries a pane command" \
  "$(printf '%s\n' "$LIST" | awk -F'\t' '$11 != "pane" && $15 != "-"' | grep -c . | tr -d ' ')" "0"
assert_eq "every node is AWAKE before anything is frozen" \
  "$(printf '%s\n' "$LIST" | awk -F'\t' '$1 != "AWAKE"' | grep -c . | tr -d ' ')" "0"
assert_eq "the planted session id is counted once, on its own pane" \
  "$(_at_level "$LIST" pane | awk -F'\t' '{s+=$8} END {print s+0}')" "1"
assert_eq "and it is attributed to the pane that hosts it" \
  "$(_at_level "$LIST" pane | awk -F'\t' -v p="$A1" '$13==p {print $8; exit}')" "1"

# ── [2] The level projections ────────────────────────────────────────────────
echo ""
echo "[2] --level projections"
LW="$(_list --level window 2>/dev/null)"
LP="$(_list --level pane 2>/dev/null)"
LS="$(_list --level session 2>/dev/null)"
printf '    --level window:\n'; printf '%s\n' "$LW" | sed 's/^/      /'
assert_eq "--level window yields exactly one row per LIVE window" \
  "$(printf '%s\n' "$LW" | awk -F'\t' '$13 ~ /^@[0-9]/ {print $13}' | sort | tr '\n' ' ')" \
  "$(_live_windows | tr '\n' ' ')"
assert_eq "--level window yields ONLY window rows" \
  "$(printf '%s\n' "$LW" | awk -F'\t' '$11 != "window"' | grep -c . | tr -d ' ')" "0"
assert_eq "--level pane yields exactly one row per live pane" \
  "$(printf '%s\n' "$LP" | awk -F'\t' '$13 ~ /^%/ {print $13}' | sort | tr '\n' ' ')" \
  "$(_live_panes | tr '\n' ' ')"
assert_eq "--level session yields exactly one row per live session" \
  "$(printf '%s\n' "$LS" | awk -F'\t' '$13 ~ /^[$]/ {print $13}' | sort | tr '\n' ' ')" \
  "$(_live_sessions | tr '\n' ' ')"
# The pre-tree contract was columns 1-10, one row per window. Columns 5 and 6 are
# a live clock and a live RSS sample and drift between two invocations by design,
# so the projection is compared on the identity and state columns.
# DO NOT "fix" this by pinning CC_NOW to make column 5 stable: an age computed
# from a pinned clock against a window created AFTER that clock was read is 0,
# and the assertion then fails a few runs in ten and looks like flakiness. If an
# age must be asserted, read it on the real clock (see freeze_restore_cycle.sh
# phase F).
_ident10() { printf '%s\n' "$1" | awk -F'\t' '$11=="window" && $13 ~ /^@[0-9]/ {
    print $1 "|" $2 "|" $3 "|" $4 "|" $7 "|" $8 "|" $9 "|" $10 }' | sort; }
assert_eq "the projected window rows are the tree's window rows, columns 1-10" \
  "$(_ident10 "$LW" | tr '\n' ' ')" "$(_ident10 "$LIST" | tr '\n' ' ')"
_assert_row_invariants "window projection" "$LW"
_assert_row_invariants "pane projection"   "$LP"
_assert_row_invariants "session projection" "$LS"

# ── [3] AWAKE -> PARTIAL: freeze ONE pane of a 3-pane window ────────────────
echo ""
echo "[3] Freeze 1 of alpha:1's 3 panes -> its window is PARTIAL 1/3, its session PARTIAL"
SESS_ALPHA="$(_t display-message -p -t alpha:1 '#{session_id}')"
SESS_BETA="$(_t display-message -p -t beta:1 '#{session_id}')"
WIN_A1="$(_t display-message -p -t alpha:1 '#{window_id}')"
WIN_A2="$(_t display-message -p -t alpha:2 '#{window_id}')"
WIN_B1="$(_t display-message -p -t beta:1 '#{window_id}')"
OUT="$(_freeze freeze --no-save "$A1" 2>/dev/null)"; RC=$?
printf '    freeze exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "the pane froze" "$(printf '%s\n' "$OUT" | awk -F'\t' '{print $1; exit}')" "FROZE"

LIST="$(_list 2>/dev/null)"
printf '%s\n' "$LIST" | sed 's/^/    /'
_assert_tree_invariants "partial" "$LIST"
assert_eq "the frozen pane's row is FROZEN"      "$(_state_of "$LIST" "$A1")" "FROZEN"
assert_eq "its untouched sibling is still AWAKE" "$(_state_of "$LIST" "$A2")" "AWAKE"
assert_eq "its other sibling is still AWAKE"     "$(_state_of "$LIST" "$A3")" "AWAKE"
assert_eq "the window is PARTIAL"                "$(_state_of "$LIST" "$WIN_A1")" "PARTIAL"
assert_eq "the window reports 1 of 3 panes frozen" "$(_frac_of "$LIST" "$WIN_A1")" "1/3"
assert_eq "the session is PARTIAL"               "$(_state_of "$LIST" "$SESS_ALPHA")" "PARTIAL"
assert_eq "the session reports 1 of 5 panes frozen" "$(_frac_of "$LIST" "$SESS_ALPHA")" "1/5"
assert_eq "the session's other window is untouched" "$(_state_of "$LIST" "$WIN_A2")" "AWAKE"
assert_eq "the OTHER session is untouched"       "$(_state_of "$LIST" "$SESS_BETA")" "AWAKE"
assert_eq "and so is its window"                 "$(_state_of "$LIST" "$WIN_B1")" "AWAKE"
assert_eq "the frozen pane's row carries its key" \
  "$(printf '%s\n' "$LIST" | awk -F'\t' -v p="$A1" '$13==p {print $9; exit}')" \
  "$(printf '%s\n' "$OUT" | awk -F'\t' '{print $3; exit}')"
assert_eq "the frozen pane's row is still one row, not a duplicate" \
  "$(printf '%s\n' "$LIST" | awk -F'\t' -v p="$A1" '$13==p' | grep -c . | tr -d ' ')" "1"
assert_eq "the tree still has 11 rows — a freeze adds no node" "$(_rowcount "$LIST")" "11"

# ── [4] PARTIAL -> FROZEN, window then session ──────────────────────────────
echo ""
echo "[4] Freeze the rest of the window, then the rest of the session"
OUT="$(_freeze freeze --no-save alpha:1 2>/dev/null)"; RC=$?
printf '    window freeze exit=%s\n' "$RC"
LIST="$(_list 2>/dev/null)"
_assert_tree_invariants "window frozen" "$LIST"
assert_eq "the window is now FROZEN"              "$(_state_of "$LIST" "$WIN_A1")" "FROZEN"
assert_eq "it reports 3 of 3 panes frozen"        "$(_frac_of "$LIST" "$WIN_A1")" "3/3"
assert_eq "the session is still PARTIAL"          "$(_state_of "$LIST" "$SESS_ALPHA")" "PARTIAL"
assert_eq "the session reports 3 of 5 panes frozen" "$(_frac_of "$LIST" "$SESS_ALPHA")" "3/5"
assert_eq "the other session is STILL untouched"  "$(_state_of "$LIST" "$SESS_BETA")" "AWAKE"

OUT="$(_freeze freeze --no-save alpha:2 2>/dev/null)"; RC=$?
printf '    second window freeze exit=%s\n' "$RC"
LIST="$(_list 2>/dev/null)"
printf '%s\n' "$LIST" | sed 's/^/    /'
_assert_tree_invariants "session frozen" "$LIST"
assert_eq "the session is now FROZEN"             "$(_state_of "$LIST" "$SESS_ALPHA")" "FROZEN"
assert_eq "it reports 5 of 5 panes frozen"        "$(_frac_of "$LIST" "$SESS_ALPHA")" "5/5"
assert_eq "every pane of the session is FROZEN" \
  "$(_at_level "$LIST" pane | awk -F'\t' -v s="$SESS_ALPHA" '$2=="alpha" && $1!="FROZEN"' | grep -c . | tr -d ' ')" "0"
assert_eq "the untouched session is AWAKE to the last row" \
  "$(printf '%s\n' "$LIST" | awk -F'\t' '$2=="beta" && $1!="AWAKE"' | grep -c . | tr -d ' ')" "0"
assert_eq "a frozen pane row reports a tombstone, not a shell" \
  "$(_at_level "$LIST" pane | awk -F'\t' -v p="$A2" '$13==p {print $15; exit}')" "tombstone"
assert_eq "the live server is unchanged: still 3 windows" "$(_live_windows | grep -c . | tr -d ' ')" "3"
assert_eq "the live server is unchanged: still 6 panes"   "$(_live_panes | grep -c . | tr -d ' ')" "6"

# The projection must keep working once containers are no longer AWAKE — this is
# where a consumer written against the flat contract would start double-counting.
LW="$(_list --level window 2>/dev/null)"
assert_eq "--level window is still one row per live window" \
  "$(printf '%s\n' "$LW" | awk -F'\t' '$13 ~ /^@[0-9]/ {print $13}' | sort | tr '\n' ' ')" \
  "$(_live_windows | tr '\n' ' ')"
assert_eq "and it still carries the aggregate state" \
  "$(printf '%s\n' "$LW" | awk -F'\t' -v w="$WIN_A1" '$13==w {print $1 " " $14 "/" $7; exit}')" "FROZEN 3/3"

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
