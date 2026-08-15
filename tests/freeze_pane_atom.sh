#!/usr/bin/env bash
# freeze_pane_atom.sh — THE PANE IS THE ATOM (design-delta-tree).
#
# Everything this file asserts is new coverage that could not exist under the
# window model, where a freeze collapsed a window and a window was the smallest
# thing you could freeze:
#
#   [1] PER-PANE FREEZE   freeze ONE pane of a 3-pane window: that pane becomes a
#                         tombstone; the other two are UNTOUCHED and their whole
#                         process trees are still alive; pane count, pane ids and
#                         `window_layout` are unchanged.
#   [2] PER-PANE THAW     thaw that one pane of a partially frozen window: only it
#                         comes back, in its recorded cwd and title, with its
#                         resume queued against its own pane id — and the panes
#                         that were never frozen are not disturbed either.
#   [3] PARTIAL           a WINDOW freeze in which one pane is REFUSED: the panes
#                         that succeeded STAY frozen (no rollback), the refusal is
#                         reported per pane with its reason, the refused pane's
#                         processes are all still alive, and the operation does
#                         not claim overall success.
#   [4] LEVEL SEMANTICS   freezing a window freezes each of its panes; freezing a
#                         session freezes each of its windows' panes. Asserted
#                         through PANE state (title + the per-pane @cc-frozen
#                         claim + one store entry per pane), never through a
#                         window-level flag — the claim moved from the window
#                         option to the pane option and a window-level assertion
#                         would pass on an implementation that never froze a pane.
#
# Contract: architecture §3.1 / §3.2 (verbs, exit codes, targets) as amended by
# design-delta-tree (pane atom, per-pane outcomes, partial is first class).
# `<target> ::= %N | session:index.pane | @N | session:index | session:`
#
# THE FIXTURE RULE. A pane that must be FREEZABLE is a BARE INTERACTIVE SHELL.
# §H4 classifies a shell carrying an operand (`sh -c '<work>'`) as
# SHELL-WITH-WORK => UNSAFE — that is the rail which stops a Claude being frozen
# mid-Bash-tool-call — so `sh -c` panes appear here ONLY in [3], where being
# refused is the entire point. Fake Claude trees reproduce the real SHAPE:
# pane -> shell -> op(wrapper) -> claude, with claude a GRANDCHILD. Leaves block
# on a writer-less FIFO rather than sleeping: `sleep` is UNSAFE by H4's last row,
# and a FIFO read forks no child and churns no pid (a pid that was not in the
# captured set is itself a stale-capture trigger, §3.1.7).
#
# "The processes are gone" is only asserted after asserting they were ALIVE, and
# every pid is iterated ONE PER LINE — `kill -0 "1 2 3"` on a joined string
# always fails, reports everything dead, and passes forever.
#
# Isolation: own tmux socket, `-f /dev/null` on EVERY tmux invocation, all state
# under /tmp, CC_TEST=1, CC_NO_NUDGE=1 so pending files stay on disk to be read.
#
# Usage: bash tests/freeze_pane_atom.sh   (exit 0 = pass)

set -uo pipefail

# ── RESURRECT SAVE-SIDE ISOLATION ────────────────────────────────────────────
# RESURRECT_FILE redirects resurrect READS. Only @resurrect-dir redirects its
# WRITES. A test that triggers a save without setting it deposits fixture
# snapshots in the user's live resurrect directory and can leave `last`
# pointing at one. See tests/lib/resurrect_guard.sh for the measured damage.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed work legacy alpha beta lvl cA cB cC cD cE

SOCKET="ccpa$$"
TD="/tmp/ccpa-$$"
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
THAW="$SCRIPT_DIR/cc_thaw.sh"

TMUX_CMD_STR="tmux -L $SOCKET -f /dev/null"
NOW="$(date +%s)"
DAY="$(date -r "$NOW" +%Y-%m-%d)"
SNOW="$(printf '\xe2\x9d\x84')"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
no()  { echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail+1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$2], want [$3]"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else no "$1" "got [$2], want anything else"; fi; }
_trunc() { printf '%s' "$1" | tr '\n' '/' | cut -c1-220; }
assert_has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "want [$3]; got [$(_trunc "$2")]" ;; esac; }
assert_hasnt() { case "$2" in *"$3"*) no "$1" "must NOT contain [$3]; got [$(_trunc "$2")]" ;; *) ok "$1" ;; esac; }

# ── PRE-FLIGHT GUARD ─────────────────────────────────────────────────────────
case "$SOCKET" in
  default|""|*/*|*\ *) echo "ABORT: unsafe socket name [$SOCKET]"; exit 1 ;;
  ccpa*) ;;
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

mkdir -p "$FD" "$PD/by-pid" "$LD" "$QD" "$RD" "$BIN" "$FIX" \
         "$TD/cwd-a" "$TD/cwd-b" "$TD/cwd-c"

MISSING=""
[ -f "$FREEZE" ] || MISSING="$MISSING $FREEZE"
[ -f "$THAW" ]   || MISSING="$MISSING $THAW"
if [ -n "$MISSING" ]; then
  echo "  FAIL: required script(s) missing:$MISSING"
  echo ""; echo "  Results: 0 passed, 1 failed"; exit 1
fi

# macOS reports symlink-resolved cwds (/tmp -> /private/tmp); a cwd assertion
# against the unresolved path fails for the wrong reason.
CWD_A="$(cd "$TD/cwd-a" && pwd -P)"
CWD_B="$(cd "$TD/cwd-b" && pwd -P)"
CWD_C="$(cd "$TD/cwd-c" && pwd -P)"

ln -s /bin/sh "$BIN/op"
ln -s /bin/sh "$BIN/claude"
mkfifo "$FIX/hold.fifo"
printf 'read _x < "%s/hold.fifo"\n' "$FIX" > "$FIX/hold.sh"
printf '"%s/claude" "%s/hold.sh"\n:\n' "$BIN" "$FIX" > "$FIX/oprun.sh"
CLAUDE_TREE_CMD="\"$BIN/op\" \"$FIX/oprun.sh\""
BUSY_SHELL_CMD="sh -c 'read _x < \"$FIX/hold.fifo\"'"

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

# work:1 trio      — 3 bare shells; panes 1 and 2 grow a Claude tree.  [1] [2]
# work:2 partial   — pane 1 + 3 freezable, pane 2 is `sh -c <work>`.   [3]
# work:3 winlevel  — 2 bare shells.                                     [4]
# lvl:1 / lvl:2    — 2 panes each, a whole session to freeze.           [4]
_t new-session -d -s work -n trio -c "$CWD_A"
_t split-window -t work:1 -c "$CWD_B"
_t split-window -t work:1 -c "$CWD_C"
_t new-window  -t work:2 -n partial -c /tmp
_t split-window -t work:2 -c /tmp "$BUSY_SHELL_CMD"
_t split-window -t work:2 -c /tmp
_t new-window  -t work:3 -n winlevel -c /tmp
_t split-window -t work:3 -c /tmp
_t new-session -d -s lvl -n one -c /tmp
_t split-window -t lvl:1 -c /tmp
_t new-window  -t lvl:2 -n two -c /tmp
_t split-window -t lvl:2 -c /tmp
_t kill-session -t _seed

NS="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NS" != "2" ]; then echo "ABORT: expected 2 sessions on the test socket, found $NS"; exit 1; fi

# ── Helpers ──────────────────────────────────────────────────────────────────
_pane_id_at()  { _t list-panes -t "$1" -F '#{pane_index} #{pane_id}' 2>/dev/null \
                   | awk -v i="$2" '$1==i { print $2; exit }'; }
_pane_count()  { _t list-panes -t "$1" 2>/dev/null | wc -l | tr -d ' '; }
_layout()      { _t display-message -p -t "$1" '#{window_layout}' 2>/dev/null; }
_pane_ids()    { _t list-panes -t "$1" -F '#{pane_index}=#{pane_id}' 2>/dev/null | tr '\n' ' '; }
_title_of()    { _t display-message -p -t "$1" '#{pane_title}' 2>/dev/null; }
_pane_pid_of() { _t display-message -p -t "$1" '#{pane_pid}' 2>/dev/null; }
_claim_of()    { _t show-options -p -t "$1" -v @cc-frozen 2>/dev/null || true; }
_win_claim()   { _t show-options -w -t "$1" -v @cc-frozen 2>/dev/null || true; }
_titles_of()   { _t list-panes -t "$1" -F '#{pane_title}' 2>/dev/null | tr '\n' '|'; }

_descendants() {
  ps -axo pid=,ppid= | awk -v r="$1" '
    { pid[NR]=$1; pp[$1]=$2; n=NR }
    END { q[1]=r; c=1; h=1
          while (h <= c) { cur=q[h]; h++
            for (i=1; i<=n; i++) if (pp[pid[i]] == cur) { c++; q[c]=pid[i] } }
          for (i=2; i<=c; i++) print q[i] }'
}
_pid_cmd() { ps -p "$1" -o command= 2>/dev/null; }
_tree_of_pane() { # <pane id> <outfile>: the pane pid AND every descendant, ONE PER LINE
  local pp; pp="$(_pane_pid_of "$1")"
  : > "$2"; [ -z "$pp" ] && return 0
  printf '%s\n' "$pp" >> "$2"; _descendants "$pp" >> "$2"
  sort -u "$2" -o "$2"
}
_count_lines() { grep -c . "$1" 2>/dev/null | tr -d ' '; }
_count_alive() { local n=0 p; while IFS= read -r p; do [ -z "$p" ] && continue
    kill -0 "$p" 2>/dev/null && n=$((n+1)); done < "$1"; printf '%s' "$n"; }
_list_alive()  { local p; while IFS= read -r p; do [ -z "$p" ] && continue
    kill -0 "$p" 2>/dev/null && printf '%s(%s) ' "$p" "$(_pid_cmd "$p" | cut -c1-32)"; done < "$1"; }

_state_count() { ls "$FD"/*/*.state 2>/dev/null | wc -l | tr -d ' '; }
_state_path()  { ls "$FD"/*/"$1.state" 2>/dev/null | head -1; }
_scalar()      { awk -F'\t' -v k="$2" '$1==k { print $2; exit }' "$1" 2>/dev/null; }
_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
_entry_for_pane() { # <pane id> -> the key of the store entry that names it, or ""
  local f
  for f in "$FD"/*/*.state; do
    [ -f "$f" ] || continue
    [ "$(_scalar "$f" pane_id)" = "$1" ] || continue
    [ -n "$(_scalar "$f" thawed_at)" ] && continue
    printf '%s' "$(_scalar "$f" key)"; return 0
  done
  return 0
}
_pending_files() { local f; for f in "$QD"/*; do [ -s "$f" ] && printf '%s\n' "$f"; done 2>/dev/null; }
_pending_count() { _pending_files | grep -c . | tr -d ' '; }

_pane_rows()    { printf '%s\n' "$1" | awk -F'\t' 'NF>=2 && $1!="WINDOW" && $1!="SESSION"'; }
_summary_rows() { printf '%s\n' "$1" | awk -F'\t' 'NF>=2 && ($1=="WINDOW" || $1=="SESSION")'; }
_row_for()      { printf '%s\n' "$1" | awk -F'\t' -v t="$2" 'NF>=2 && $2==t { print; exit }'; }
_col()          { printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NF>=2 { print $n; exit }'; }
_nrows()        { printf '%s\n' "$1" | grep -c . | tr -d ' '; }
_verbs()        { _pane_rows "$1" | awk -F'\t' '{print $1}' | sort | tr '\n' ' '; }

# The freeze/thaw exit codes, as documented in cc_freeze.sh's header:
#   0  every targeted pane froze
#   4  SOME froze — a PARTIAL SUCCESS, not a failure
#   3  none froze, rails only (all skipped)
#   2  none froze, and at least one FAILED/PARTIAL error occurred
#   1  usage error
# (`sweep` is exempt: it exits 0 whenever it ran, and requires unanimity.)
# A partial freeze is therefore 4 exactly — not 0, which would claim unanimous
# success, and not 2, which would call a partial success a failure.
_freeze() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_NO_SAVE=1 CC_NO_NUDGE=1 bash "$FREEZE" "$@"
}
_thaw() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_NO_SAVE=1 CC_NO_NUDGE=1 bash "$THAW" "$@"
}

# ── Grow the fake Claude trees ───────────────────────────────────────────────
_claude_procs() { ps -axo pid=,command= \
    | awk -v b="$BIN" -v s="/claude " 'index($0, b s) { n++ } END { print n+0 }'; }
_grow() { # <pane_id> <total claude procs expected once it is up>
  local _try
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ "$(_claude_procs)" -ge "$2" ] && return 0
    case "$_try" in 1|5|9) _t send-keys -t "$1" "$CLAUDE_TREE_CMD" Enter ;; esac
    sleep 0.4
  done
  [ "$(_claude_procs)" -ge "$2" ]
}
A1="$(_pane_id_at work:1 1)"; A2="$(_pane_id_at work:1 2)"; A3="$(_pane_id_at work:1 3)"
if [ -z "$A1" ] || [ -z "$A2" ] || [ -z "$A3" ]; then
  echo "ABORT: could not resolve the three panes of work:1"; exit 1
fi
_t select-pane -t "$A1" -T "atom-pane-one"
_t select-pane -t "$A2" -T "atom-pane-two"
_t select-pane -t "$A3" -T "atom-pane-three"
_grow "$A1" 1 || echo "  (warning: pane 1's claude tree did not come up)"
_grow "$A2" 2 || echo "  (warning: pane 2's claude tree did not come up)"

_claude_in_pane() { # <pane id> -> first descendant whose command is our fake claude
  local p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$(_pid_cmd "$p")" in "$BIN/claude"*) printf '%s' "$p"; return 0 ;; esac
  done < <(_descendants "$(_pane_pid_of "$1")")
  return 1
}

# ── [0] PREMISE ──────────────────────────────────────────────────────────────
echo "[0] PREMISE: a 3-pane window whose panes 1 and 2 each host a claude GRANDCHILD"
CLAUDE_1=""; CLAUDE_2=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
  CLAUDE_1="$(_claude_in_pane "$A1" || true)"
  CLAUDE_2="$(_claude_in_pane "$A2" || true)"
  [ -n "$CLAUDE_1" ] && [ -n "$CLAUDE_2" ] && break
  sleep 0.4
done
assert_eq "work:1 has 3 panes" "$(_pane_count work:1)" "3"
if [ -n "$CLAUDE_1" ]; then ok "pane 1 hosts a live claude ($CLAUDE_1)"
else no "pane 1 hosts a live claude" "no descendant matching $BIN/claude"; fi
if [ -n "$CLAUDE_2" ]; then ok "pane 2 hosts a live claude ($CLAUDE_2)"
else no "pane 2 hosts a live claude" "no descendant matching $BIN/claude"; fi
if [ -n "$CLAUDE_1" ]; then
  assert_ne "claude is a GRANDCHILD, not a direct child of the pane" \
    "$(ps -p "$CLAUDE_1" -o ppid= 2>/dev/null | tr -d ' ')" "$(_pane_pid_of "$A1")"
fi
_tree_of_pane "$A1" "$TD/tree_a1"
_tree_of_pane "$A2" "$TD/tree_a2"
_tree_of_pane "$A3" "$TD/tree_a3"
assert_eq "every pid of pane 1 is ALIVE before the freeze ($(_count_lines "$TD/tree_a1"))" \
  "$(_count_alive "$TD/tree_a1")" "$(_count_lines "$TD/tree_a1")"
assert_eq "every pid of pane 2 is ALIVE before the freeze ($(_count_lines "$TD/tree_a2"))" \
  "$(_count_alive "$TD/tree_a2")" "$(_count_lines "$TD/tree_a2")"
assert_eq "every pid of pane 3 is ALIVE before the freeze ($(_count_lines "$TD/tree_a3"))" \
  "$(_count_alive "$TD/tree_a3")" "$(_count_lines "$TD/tree_a3")"
if [ "$fail" -ne 0 ]; then
  echo ""; echo "  Results: $pass passed, $fail failed (premise not established)"; exit 1
fi

SID_1="11111111-aaaa-4aaa-8aaa-111111111111"
SID_2="22222222-bbbb-4bbb-8bbb-222222222222"
[ -n "$CLAUDE_1" ] && echo "$SID_1" > "$PD/by-pid/$CLAUDE_1.session-id"
[ -n "$CLAUDE_2" ] && echo "$SID_2" > "$PD/by-pid/$CLAUDE_2.session-id"

# ── [1] PER-PANE FREEZE ──────────────────────────────────────────────────────
echo ""
echo "[1] Freeze ONE pane of a 3-pane window (target %N, the new atom)"
LAYOUT_1_BEFORE="$(_layout work:1)"
IDS_1_BEFORE="$(_pane_ids work:1)"
PID_A2_BEFORE="$(_pane_pid_of "$A2")"
PID_A3_BEFORE="$(_pane_pid_of "$A3")"
TITLE_A2_BEFORE="$(_title_of "$A2")"
TITLE_A3_BEFORE="$(_title_of "$A3")"
STATES_BEFORE="$(_state_count)"
printf '    layout before: %s\n    panes before:  %s\n' "$LAYOUT_1_BEFORE" "$IDS_1_BEFORE"

OUT="$(_freeze freeze --no-save "$A1" 2>"$TD/e1")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
[ -s "$TD/e1" ] && printf '    stderr: %s\n' "$(head -3 "$TD/e1")"

assert_eq "exit code 0"                              "$RC" "0"
assert_eq "exactly one row — a pane target is one atom" "$(_nrows "$OUT")" "1"
assert_eq "the verb is FROZE"                        "$(_col "$OUT" 1)" "FROZE"
assert_eq "the row names the pane, session:index.pane" "$(_col "$OUT" 2)" "work:1.1"
assert_eq "the row counts one pane"                  "$(_col "$OUT" 4)" "1"
assert_eq "the row counts that pane's one sid"       "$(_col "$OUT" 5)" "1"
KEY_A1="$(_col "$OUT" 3)"
assert_ne "the row carries a key"                    "$KEY_A1" "-"

# the frozen pane
assert_eq "the frozen pane wears the tombstone title" "$(_title_of "$A1")" \
  "$(printf '%s FROZEN %s 1p/1s %s' "$SNOW" "$KEY_A1" "$DAY")"
assert_eq "the frozen pane claims its key as a PANE option" "$(_claim_of "$A1")" "$KEY_A1"
assert_eq "allow-rename is off on the frozen pane" \
  "$(_t show-options -p -t "$A1" -v allow-rename 2>/dev/null)" "off"
assert_eq "exactly one new store entry"            "$(_state_count)" "$((STATES_BEFORE+1))"
SF_A1="$(_state_path "$KEY_A1")"
if [ -n "$SF_A1" ] && [ -s "$SF_A1" ]; then
  ok "the store entry exists ($SF_A1)"
  assert_eq "the entry's unit is a pane"        "$(_scalar "$SF_A1" unit)" "pane"
  assert_eq "the entry names this pane id"      "$(_scalar "$SF_A1" pane_id)" "$A1"
  assert_eq "the entry records the pane index"  "$(_scalar "$SF_A1" pane_index)" "1"
  assert_eq "the entry records this pane's cwd" "$(_b64d "$(_scalar "$SF_A1" primary_cwd)")" "$CWD_A"
  assert_eq "the entry records one sid"         "$(_scalar "$SF_A1" sid_count)" "1"
  assert_has "the entry records THIS pane's sid" "$(cat "$SF_A1")" "$SID_1"
  assert_hasnt "and not the neighbour's sid"     "$(cat "$SF_A1")" "$SID_2"
else
  no "the store entry exists" "no $FD/*/$KEY_A1.state"
fi
for _w in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(_count_alive "$TD/tree_a1")" = "0" ] && break; sleep 0.3
done
if [ "$(_count_alive "$TD/tree_a1")" = "0" ]; then
  ok "every pid of the frozen pane's tree is dead ($(_count_lines "$TD/tree_a1") pids, all ALIVE before)"
else
  no "every pid of the frozen pane's tree is dead" "still alive: $(_list_alive "$TD/tree_a1")"
fi

# the window: NOT restructured
assert_eq "the window still has 3 panes"           "$(_pane_count work:1)" "3"
assert_eq "window_layout is byte-identical"        "$(_layout work:1)" "$LAYOUT_1_BEFORE"
assert_eq "every pane kept its pane id"            "$(_pane_ids work:1)" "$IDS_1_BEFORE"

# THE POINT: the other two panes are untouched
assert_eq "neighbour pane 2 was not respawned (pane_pid unchanged)" "$(_pane_pid_of "$A2")" "$PID_A2_BEFORE"
assert_eq "neighbour pane 3 was not respawned (pane_pid unchanged)" "$(_pane_pid_of "$A3")" "$PID_A3_BEFORE"
assert_eq "neighbour pane 2 keeps its title"       "$(_title_of "$A2")" "$TITLE_A2_BEFORE"
assert_eq "neighbour pane 3 keeps its title"       "$(_title_of "$A3")" "$TITLE_A3_BEFORE"
assert_eq "neighbour pane 2 carries NO frozen claim" "$(_claim_of "$A2")" ""
assert_eq "neighbour pane 3 carries NO frozen claim" "$(_claim_of "$A3")" ""
assert_eq "no store entry names neighbour pane 2"  "$(_entry_for_pane "$A2")" ""
assert_eq "no store entry names neighbour pane 3"  "$(_entry_for_pane "$A3")" ""
assert_eq "neighbour pane 2's WHOLE tree is still alive ($(_count_lines "$TD/tree_a2") pids)" \
  "$(_count_alive "$TD/tree_a2")" "$(_count_lines "$TD/tree_a2")"
assert_eq "neighbour pane 3's WHOLE tree is still alive ($(_count_lines "$TD/tree_a3") pids)" \
  "$(_count_alive "$TD/tree_a3")" "$(_count_lines "$TD/tree_a3")"
# the neighbour's claude is specifically still running — freezing a pane must not
# reach a sibling's process tree, which is the failure this whole model risks.
if [ -n "$CLAUDE_2" ]; then
  if kill -0 "$CLAUDE_2" 2>/dev/null; then ok "the neighbour's claude process ($CLAUDE_2) is still running"
  else no "the neighbour's claude process is still running" "pid $CLAUDE_2 was killed by a sibling's freeze"; fi
fi
# the claim is per pane, not per window: a partially frozen window must not be
# marked frozen at the window level or a window-level reader will freeze/thaw all
# of it by accident.
assert_eq "the WINDOW carries no @cc-frozen claim" "$(_win_claim work:1)" ""

# ── [2] PER-PANE THAW ────────────────────────────────────────────────────────
echo ""
echo "[2] Thaw that ONE pane of the partially frozen window"
rm -f "$QD"/*
PID_A1_FROZEN="$(_pane_pid_of "$A1")"
OUT="$(_thaw thaw --no-save "$A1" 2>"$TD/e2")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
[ -s "$TD/e2" ] && printf '    stderr: %s\n' "$(head -3 "$TD/e2")"

assert_eq "exit code 0"                        "$RC" "0"
assert_eq "exactly one row for one pane"       "$(_nrows "$OUT")" "1"
assert_eq "the verb is THAWED"                 "$(_col "$OUT" 1)" "THAWED"
assert_eq "the row names the pane"             "$(_col "$OUT" 2)" "work:1.1"
assert_eq "the row reports its key"            "$(_col "$OUT" 3)" "$KEY_A1"
assert_eq "the row reports one pane"           "$(_col "$OUT" 4)" "1"
assert_eq "the row reports one queued resume"  "$(_col "$OUT" 5)" "1"

assert_eq "the pane came back in its recorded cwd" \
  "$(_t display-message -p -t "$A1" '#{pane_current_path}')" "$CWD_A"
assert_eq "the pane came back with its recorded title" "$(_title_of "$A1")" "atom-pane-one"
assert_eq "the pane's frozen claim is cleared"         "$(_claim_of "$A1")" ""
assert_ne "the pane was respawned to thaw it (pane_pid changed)" \
  "$(_pane_pid_of "$A1")" "$PID_A1_FROZEN"
assert_eq "the pane id never changed"                  "$(_pane_ids work:1)" "$IDS_1_BEFORE"
assert_eq "the window still has 3 panes"               "$(_pane_count work:1)" "3"
assert_eq "window_layout is still byte-identical"      "$(_layout work:1)" "$LAYOUT_1_BEFORE"

# the resume is queued against THIS pane, and nothing else was queued. A bug in
# this repo once "worked" while writing its token into a different pane, so the
# key of the pending file is asserted, not just its content.
assert_eq "exactly one pending resume was queued" "$(_pending_count)" "1"
PENDING_FILE="$(_pending_files | head -1)"
assert_eq "it is keyed by the thawed pane's OWN id" "%${PENDING_FILE##*/}" "$A1"
assert_has "it resumes the recorded session id" "$(cat "$PENDING_FILE" 2>/dev/null)" "--resume $SID_1"
assert_hasnt "it does not carry the neighbour's session id" "$(cat "$PENDING_FILE" 2>/dev/null)" "$SID_2"

# the never-frozen neighbours are still not disturbed by the thaw either
assert_eq "neighbour pane 2 still not respawned" "$(_pane_pid_of "$A2")" "$PID_A2_BEFORE"
assert_eq "neighbour pane 3 still not respawned" "$(_pane_pid_of "$A3")" "$PID_A3_BEFORE"
assert_eq "neighbour pane 2's tree is still alive" \
  "$(_count_alive "$TD/tree_a2")" "$(_count_lines "$TD/tree_a2")"
assert_eq "neighbour pane 3's tree is still alive" \
  "$(_count_alive "$TD/tree_a3")" "$(_count_lines "$TD/tree_a3")"
assert_hasnt "no pane of the window still wears a tombstone title" \
  "$(_titles_of work:1)" "$SNOW FROZEN"

# ── [3] PARTIAL: one refused pane must not roll back the others ─────────────
echo ""
echo "[3] A window freeze where one pane is REFUSED (partial outcomes are first class)"
B1="$(_pane_id_at work:2 1)"; B2="$(_pane_id_at work:2 2)"; B3="$(_pane_id_at work:2 3)"
if [ -z "$B1" ] || [ -z "$B2" ] || [ -z "$B3" ]; then
  echo "ABORT: could not resolve the three panes of work:2"; exit 1
fi
_tree_of_pane "$B2" "$TD/tree_b2"
assert_eq "the unsafe pane's tree is ALIVE before the freeze ($(_count_lines "$TD/tree_b2") pids)" \
  "$(_count_alive "$TD/tree_b2")" "$(_count_lines "$TD/tree_b2")"
LAYOUT_2_BEFORE="$(_layout work:2)"
IDS_2_BEFORE="$(_pane_ids work:2)"
PID_B2_BEFORE="$(_pane_pid_of "$B2")"
STATES_BEFORE="$(_state_count)"

OUT="$(_freeze freeze --no-save work:2 2>"$TD/e3")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
PANE_ROWS="$(_pane_rows "$OUT")"
SUMMARY="$(_summary_rows "$OUT")"

assert_eq "one row per pane, all three reported" "$(_nrows "$PANE_ROWS")" "3"
assert_eq "two panes froze and one was refused"  "$(_verbs "$OUT")" "FROZE FROZE REFUSED "
REFUSED_ROW="$(_row_for "$OUT" work:2.2)"
assert_eq "the refused row is the shell-with-work pane" "$(_col "$REFUSED_ROW" 1)" "REFUSED"
assert_has "the refusal names its reason (§3.1 reason vocabulary)" \
  "$(_col "$REFUSED_ROW" 6)" "unsafe-process:"
assert_eq "a refused pane is given no key"       "$(_col "$REFUSED_ROW" 3)" "-"

# NO ROLLBACK: the two that succeeded stay frozen.
assert_eq "pane 1 stayed frozen"  "$(_col "$(_row_for "$OUT" work:2.1)" 1)" "FROZE"
assert_eq "pane 3 stayed frozen"  "$(_col "$(_row_for "$OUT" work:2.3)" 1)" "FROZE"
KEY_B1="$(_col "$(_row_for "$OUT" work:2.1)" 3)"
KEY_B3="$(_col "$(_row_for "$OUT" work:2.3)" 3)"
assert_has "pane 1 wears its tombstone title"  "$(_title_of "$B1")" "$SNOW FROZEN $KEY_B1"
assert_has "pane 3 wears its tombstone title"  "$(_title_of "$B3")" "$SNOW FROZEN $KEY_B3"
assert_eq "pane 1 claims its key"              "$(_claim_of "$B1")" "$KEY_B1"
assert_eq "pane 3 claims its key"              "$(_claim_of "$B3")" "$KEY_B3"
assert_eq "two store entries were kept, not rolled back" "$(_state_count)" "$((STATES_BEFORE+2))"

# the REFUSED pane is untouched — nothing written, nothing killed (NFR1)
assert_eq "the refused pane carries no frozen claim" "$(_claim_of "$B2")" ""
assert_eq "no store entry names the refused pane"    "$(_entry_for_pane "$B2")" ""
assert_eq "the refused pane was not respawned"       "$(_pane_pid_of "$B2")" "$PID_B2_BEFORE"
assert_hasnt "the refused pane wears no tombstone title" "$(_title_of "$B2")" "$SNOW FROZEN"
assert_eq "every pid of the refused pane's tree is STILL ALIVE" \
  "$(_count_alive "$TD/tree_b2")" "$(_count_lines "$TD/tree_b2")"

# the window is still not restructured, even half frozen
assert_eq "the partially frozen window still has 3 panes" "$(_pane_count work:2)" "3"
assert_eq "its layout is byte-identical"                  "$(_layout work:2)" "$LAYOUT_2_BEFORE"
assert_eq "its pane ids are unchanged"                    "$(_pane_ids work:2)" "$IDS_2_BEFORE"

# The operation must not claim unanimous success, and must not be mistaken for a
# failure either: 4 is the documented code for "SOME froze".
assert_ne "the exit code does not claim unanimous success" "$RC" "0"
assert_eq "a partial freeze exits 4 (PARTIAL SUCCESS, not 0 and not 2)" "$RC" "4"
assert_eq "exactly one container summary row" "$(_nrows "$SUMMARY")" "1"
assert_eq "the summary is the WINDOW level"   "$(_col "$SUMMARY" 1)" "WINDOW"
# The container verdict vocabulary is ALL | PARTIAL | NONE.
assert_eq "the container verdict is PARTIAL"  "$(_col "$SUMMARY" 3)" "PARTIAL"
assert_eq "the summary's last column is the window's pane count" \
  "$(printf '%s\n' "$SUMMARY" | awk -F'\t' '{print $NF; exit}')" "3"

# and a re-run is stable: the frozen stay ALREADY, the refused stays REFUSED
OUT="$(_freeze freeze --no-save work:2 2>/dev/null)"; RC=$?
assert_eq "re-freezing a partially frozen window is stable" "$(_verbs "$OUT")" "ALREADY ALREADY REFUSED "
assert_eq "the refused pane's tree is STILL alive after the re-run" \
  "$(_count_alive "$TD/tree_b2")" "$(_count_lines "$TD/tree_b2")"
assert_eq "no extra store entry was written by the re-run" "$(_state_count)" "$((STATES_BEFORE+2))"

# ── [4] LEVEL SEMANTICS ──────────────────────────────────────────────────────
echo ""
echo "[4a] Freezing a WINDOW freezes each of its panes"
C1P="$(_pane_id_at work:3 1)"; C2P="$(_pane_id_at work:3 2)"
LAYOUT_3_BEFORE="$(_layout work:3)"
STATES_BEFORE="$(_state_count)"
OUT="$(_freeze freeze --no-save work:3 2>/dev/null)"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "exit code 0"                       "$RC" "0"
assert_eq "one row per pane of the window"    "$(_nrows "$(_pane_rows "$OUT")")" "2"
assert_eq "both panes froze"                  "$(_verbs "$OUT")" "FROZE FROZE "
# asserted through PANE state, never a window flag
KC1="$(_claim_of "$C1P")"; KC2="$(_claim_of "$C2P")"
assert_ne "pane 1 of the window claims a key" "$KC1" ""
assert_ne "pane 2 of the window claims a key" "$KC2" ""
assert_ne "the two panes hold DIFFERENT keys — one entry per pane" "$KC1" "$KC2"
assert_has "pane 1 wears a tombstone title"   "$(_title_of "$C1P")" "$SNOW FROZEN $KC1"
assert_has "pane 2 wears a tombstone title"   "$(_title_of "$C2P")" "$SNOW FROZEN $KC2"
assert_eq "one store entry per pane"          "$(_state_count)" "$((STATES_BEFORE+2))"
assert_eq "the window itself carries no @cc-frozen flag" "$(_win_claim work:3)" ""
assert_eq "the window still has 2 panes"      "$(_pane_count work:3)" "2"
assert_eq "its layout is byte-identical"      "$(_layout work:3)" "$LAYOUT_3_BEFORE"

echo ""
echo "[4b] Freezing a SESSION freezes every pane of every one of its windows"
L11="$(_pane_id_at lvl:1 1)"; L12="$(_pane_id_at lvl:1 2)"
L21="$(_pane_id_at lvl:2 1)"; L22="$(_pane_id_at lvl:2 2)"
LAYOUT_L1="$(_layout lvl:1)"; LAYOUT_L2="$(_layout lvl:2)"
STATES_BEFORE="$(_state_count)"
WINDOWS_L_BEFORE="$(_t list-windows -t lvl -F '#{window_index}:#{window_name}' | tr '\n' ' ')"
OUT="$(_freeze freeze --no-save lvl: 2>/dev/null)"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "exit code 0"                        "$RC" "0"
assert_eq "one row per pane of the session"    "$(_nrows "$(_pane_rows "$OUT")")" "4"
assert_eq "all four panes froze"               "$(_verbs "$OUT")" "FROZE FROZE FROZE FROZE "
assert_eq "the pane rows name every pane of both windows" \
  "$(_pane_rows "$OUT" | awk -F'\t' '{print $2}' | sort | tr '\n' ' ')" \
  "lvl:1.1 lvl:1.2 lvl:2.1 lvl:2.2 "
# summaries: one per window plus one for the session, all distinguishable from
# pane rows so a counter cannot treble-count the same freeze
SUMMARY_L="$(_summary_rows "$OUT")"
assert_eq "three container summaries (2 windows + 1 session)" "$(_nrows "$SUMMARY_L")" "3"
assert_eq "exactly one of them is the SESSION level" \
  "$(printf '%s\n' "$SUMMARY_L" | awk -F'\t' '$1=="SESSION"' | grep -c . | tr -d ' ')" "1"
assert_eq "the session summary names the session" \
  "$(printf '%s\n' "$SUMMARY_L" | awk -F'\t' '$1=="SESSION" {print $2; exit}')" "lvl"
# every pane, asserted through PANE state
NOCLAIM=0; NOTOMB=0
for p in "$L11" "$L12" "$L21" "$L22"; do
  k="$(_claim_of "$p")"
  [ -n "$k" ] || NOCLAIM=$((NOCLAIM+1))
  case "$(_title_of "$p")" in "$SNOW FROZEN $k "*) ;; *) NOTOMB=$((NOTOMB+1)) ;; esac
done
assert_eq "every pane of every window claims a key" "$NOCLAIM" "0"
assert_eq "every pane of every window is a tombstone" "$NOTOMB" "0"
assert_eq "one store entry per pane of the session"  "$(_state_count)" "$((STATES_BEFORE+4))"
assert_eq "neither window carries a window-level flag" \
  "$(_win_claim lvl:1)$(_win_claim lvl:2)" ""
assert_eq "no window of the session was restructured" \
  "$(_pane_count lvl:1)$(_pane_count lvl:2)" "22"
assert_eq "lvl:1 layout is byte-identical" "$(_layout lvl:1)" "$LAYOUT_L1"
assert_eq "lvl:2 layout is byte-identical" "$(_layout lvl:2)" "$LAYOUT_L2"
assert_eq "no window was renumbered" \
  "$(_t list-windows -t lvl -F '#{window_index}:#{window_name}' | tr '\n' ' ')" "$WINDOWS_L_BEFORE"
assert_eq "the session still has 2 windows" "$(_t list-windows -t lvl | wc -l | tr -d ' ')" "2"
# a session freeze must not have leaked into the OTHER session
assert_eq "the other session's untouched panes are still awake" \
  "$(_claim_of "$A2")$(_claim_of "$A3")$(_claim_of "$B2")" ""

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
