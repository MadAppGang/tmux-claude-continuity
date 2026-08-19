#!/usr/bin/env bash
# popup_restore_plan.sh — the popup must show THE COMMAND, not a likeness of it.
#
# `cc_popup.sh --preview` is a black-box surface: given one rendered row it
# prints what a freeze would put back (awake) or what a wake will run (frozen).
# The feature it carries is that a CONTAINER row answers for every pane beneath
# it, because a container is the row C-F and C-W are actually pressed on.
#
# What is asserted here:
#   [1] WINDOW PLAN     a window row lists ONE plan row per pane it owns, and the
#                       command carries the pane's own session id.
#   [2] TYPED WINS      when the preexec capture holds the command the user
#                       actually typed, that is what is shown — the same
#                       precedence cc_compose_relaunch applies, not a rebuild.
#   [3] SESSION PLAN    a session row spans its windows: every pane, both
#                       windows, one row each.
#   [4] SHELL IS REAL   a pane with no session is not "unknown": cc_thaw.sh
#                       writes a pending file only per `sid` RECORD, so such a
#                       pane is respawned with _cc_fresh_shell and nothing else,
#                       and the plan says exactly that.
#   [5] CLAUDISH        REGRESSION. A frozen claudish entry must preview through
#                       `claudish` with its replay flags. The first version read
#                       `;CLAUDISH_REPLAY=` — the resurrect SNAPSHOT's name for
#                       that fact — from a STORE record that spells it `;REPLAY=`
#                       and stores it base64, so it found nothing and every
#                       claudish pane previewed as the bare `claude --resume`
#                       its own thaw is written to never run (wrong account,
#                       wrong model).
#   [6] SECONDARY       a secondary session is never auto-resumed, so it must not
#                       be shown as a command that will run.
#   [7] CAP             a bounded list must say what it left out: silence reads
#                       as "that was all of them".
#
# THE FIXTURE RULE (inherited from list_tree_contract.sh): every pane is a BARE
# INTERACTIVE SHELL, and the one fake Claude is grown as pane -> op -> claude so
# the sid climb has a real depth-2 tree to walk. Its leaf blocks on a
# writer-less FIFO: `sleep` is UNSAFE by H4's last row, and a FIFO read forks no
# child and churns no pid.
#
# Isolation: own tmux socket, `-f /dev/null` on EVERY tmux invocation, all state
# under /tmp, CC_TEST=1.
#
# Usage: bash tests/popup_restore_plan.sh   (exit 0 = pass)

set -uo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed alpha beta wide

SOCKET="ccrp$$"
TD="/tmp/ccrp-$$"
FD="$TD/frozen"
PD="$TD/panes"
LD="$TD/launch"
QD="$TD/pending"
RD="$TD/resurrect"
BIN="$TD/bin"
FIX="$TD/fix"
W="$TD/work"
LOG="$TD/cc.log"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
POPUP="$SCRIPT_DIR/cc_popup.sh"
STORE="$SCRIPT_DIR/lib/cc_store.sh"

TMUX_CMD_STR="tmux -L $SOCKET -f /dev/null"
NOW="$(date +%s)"
TAB="$(printf '\t')"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
no()  { echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail+1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$2], want [$3]"; fi; }
assert_has() { # <name> <haystack> <needle>
  # The tail of what was actually printed, on failure. A previewer's assertion
  # that says only "not found" sends you back to re-run it by hand.
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) no "$1" "[$3] not in: …$(printf '%s' "$2" | tr '\n' '/' | tail -c 220)" ;;
  esac
}
assert_hasnt() { # <name> <haystack> <needle>
  case "$2" in *"$3"*) no "$1" "[$3] present and must not be" ;; *) ok "$1" ;; esac
}

# ── PRE-FLIGHT GUARD ─────────────────────────────────────────────────────────
case "$SOCKET" in
  default|""|*/*|*\ *) echo "ABORT: unsafe socket name [$SOCKET]"; exit 1 ;;
  ccrp*) ;;
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
_cc_teardown_guarded() { _teardown; cc_warn_on_resurrect_leak || exit 1; }
trap _cc_teardown_guarded EXIT INT TERM

mkdir -p "$FD" "$PD/by-pid" "$LD" "$QD" "$RD" "$BIN" "$FIX" "$W"

[ -f "$POPUP" ] || { echo "  FAIL: $POPUP is missing"; echo "  Results: 0 passed, 1 failed"; exit 1; }

ln -s /bin/sh "$BIN/op"
ln -s /bin/sh "$BIN/claude"
mkfifo "$FIX/hold.fifo"
printf 'read _x < "%s/hold.fifo"\n' "$FIX" > "$FIX/hold.sh"
printf '"%s/claude" "%s/hold.sh"\n:\n' "$BIN" "$FIX" > "$FIX/oprun.sh"
CLAUDE_TREE_CMD="\"$BIN/op\" \"$FIX/oprun.sh\""

# A wide server: the cap assertion needs 15 panes in one window, and tmux
# refuses a split that has no room.
_t new-session -d -s _seed -c /tmp -x 300 -y 120
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
cc_guard_resurrect_dir "$RD" tmux -L "$SOCKET" -f /dev/null

# alpha:1 three (3 panes: one fake-Claude tree, two bare shells) · alpha:2 solo
_t new-session -d -s alpha -n three -c /tmp -x 300 -y 120
_t split-window -t alpha:1 -c /tmp
_t split-window -t alpha:1 -c /tmp
_t new-window -t alpha:2 -n solo -c /tmp
_t kill-session -t _seed

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
B1="$(_pane_id_at alpha:2 1)"
WID1="$(_t display-message -p -t alpha:1 '#{window_id}')"
WID2="$(_t display-message -p -t alpha:2 '#{window_id}')"
SESSID="$(_t display-message -p -t alpha:1 '#{session_id}')"

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
if [ -z "$CLAUDE_PID" ]; then
  echo "ABORT: the fake Claude tree never came up"; exit 1
fi
echo "$SID_A" > "$PD/by-pid/$CLAUDE_PID.session-id"

# The preexec capture for that pane: the command the user actually typed.
TYPED='c --model opus'
printf '%s\n' "$TYPED" > "$LD/${A1#%}"

_env() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_POPUP_NOCOLOR=1 CC_POPUP_ASCII=1 "$@"
}
_list() { _env bash "$POPUP" --list "$@"; }
# The preview reads the cached inventory out of the work dir exactly as an fzf
# child does; priming it here is what makes this a black-box drive of the same
# code path rather than a special case.
# `env`, not a bare assignment: a VAR=x that arrives by EXPANSION is a command
# NAME, not an assignment, so `_env CC_POPUP_WORK=… bash …` tries to execute a
# file called CC_POPUP_WORK=… and the preview never runs.
_preview() { # <node> <level> <state> <key> <wid> <target> <label>
  _env env CC_POPUP_WORK="$W" FZF_PREVIEW_COLUMNS=76 bash "$POPUP" --preview \
    "$(printf 'disp\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7")"
}
_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
# A COMMAND assertion must not depend on the preview's width. Long commands are
# folded at word boundaries so they can be read and copied, so a command is
# asserted against the unfolded text: `fold -s` never splits a token, and
# collapsing the line breaks back to single spaces reproduces the command
# exactly. Assert commands through this; assert layout on the raw output.
_flat() { printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g'; }
_plan_rows() { # count the plan's per-pane rows in a preview
  printf '%s\n' "$1" | awk '/^ +[ *] %[0-9]+ /' | wc -l | tr -d ' '
}

_list > "$W/inv" 2>/dev/null
if [ ! -s "$W/inv" ]; then echo "ABORT: --list produced nothing"; exit 1; fi

echo ""
echo "── [1] a window row plans every pane it owns ─────────────────────────"
OUT="$(_preview "$WID1" window AWAKE - "$WID1" alpha:1 three)"
assert_has "the plan is present" "$OUT" "RESTORE PLAN"
assert_eq  "one plan row per pane in the window" "$(_plan_rows "$OUT")" "3"
assert_has "the claude pane resumes" "$OUT" "RESUME"
assert_has "with its own session id" "$(_flat "$OUT")" "--resume $SID_A"

echo ""
echo "── [2] the typed command wins, as it does in a real wake ─────────────"
assert_has "the preexec capture is what is shown" "$(_flat "$OUT")" "$TYPED --resume $SID_A"
assert_hasnt "the configured launcher did not overwrite it" "$OUT" "echo --resume"

echo ""
echo "── [3] a session row spans its windows ───────────────────────────────"
OUT="$(_preview "$SESSID" session AWAKE - - alpha:- alpha)"
assert_has "the plan is present" "$OUT" "RESTORE PLAN"
assert_eq  "every pane of both windows" "$(_plan_rows "$OUT")" "4"
assert_has "the window table is still there" "$OUT" "MEMORY"

echo ""
echo "── [4] a pane with no session is respawned as a shell, and says so ───"
OUT="$(_preview "$A2" pane AWAKE - "$WID1" alpha:1 sh)"
assert_has "no session is a stated outcome" "$OUT" "No Claude session here"
assert_has "and names the command that runs" "$(_flat "$OUT")" "sh -i"
assert_hasnt "no resume is offered" "$OUT" "--resume"

echo ""
echo "── [5] REGRESSION: a frozen claudish entry previews THROUGH claudish ──"
KEY_C="$(_env bash "$STORE" mint | tr -d '\n')"
SC="$(_env bash "$STORE" path "$KEY_C" | tr -d '\n')"
SID_C="11111111-cccc-4ccc-8ccc-111111111111"
REPLAY_C='-d --model cx@gpt-5.6-sol'
{
  printf 'unit\tpane\n'
  printf 'frozen_at\t%s\n' "$NOW"
  printf 'idle_at_freeze\t0\n'
  printf 'rss_at_freeze\t123456\n'
  printf 'pane_count\t1\n'
  printf 'sid_count\t1\n'
  printf 'primary_cwd\t%s\n' "$(_b64 /tmp)"
  printf 'reason\tmanual\n'
  printf 'pane\t1\t;CWD=%s\t;TITLE=%s\t;CMD=%s\t;PID=1\t;PPID=1\t;CLASS=claudish\n' \
    "$(_b64 /tmp)" "$(_b64 'work')" "$(_b64 'node /opt/bin/claudish -d')"
  printf 'sid\t1\t;CLAUDE_SID=%s\t;ROLE=primary\t;PID=1\t;REPLAY=%s\t;CLASS=claudish\n' \
    "$SID_C" "$(_b64 "$REPLAY_C")"
} > "$SC"
OUT="$(_preview '%90' pane FROZEN "$KEY_C" "$WID1" alpha:1 work)"
assert_has "relaunched through claudish" "$(_flat "$OUT")" "claudish $REPLAY_C --resume $SID_C"
assert_hasnt "never as a bare claude resume" "$OUT" "echo --resume $SID_C"

echo ""
echo "── [6] a secondary session is shown, never offered as a command ──────"
KEY_S="$(_env bash "$STORE" mint | tr -d '\n')"
SS="$(_env bash "$STORE" path "$KEY_S" | tr -d '\n')"
SID_S="22222222-cccc-4ccc-8ccc-222222222222"
{
  printf 'unit\tpane\n'
  printf 'frozen_at\t%s\n' "$NOW"
  printf 'idle_at_freeze\t0\n'
  printf 'rss_at_freeze\t1024\n'
  printf 'pane_count\t1\n'
  printf 'sid_count\t1\n'
  printf 'primary_cwd\t%s\n' "$(_b64 /tmp)"
  printf 'reason\tmanual\n'
  printf 'pane\t1\t;CWD=%s\t;TITLE=%s\t;CMD=%s\t;PID=1\t;PPID=1\t;CLASS=claude\n' \
    "$(_b64 /tmp)" "$(_b64 'second')" "$(_b64 '/bin/sh')"
  printf 'sid\t1\t;CLAUDE_SID=%s\t;ROLE=secondary\t;PID=1\t;CLASS=claude\n' "$SID_S"
} > "$SS"
OUT="$(_preview '%91' pane FROZEN "$KEY_S" "$WID1" alpha:1 second)"
assert_has "the id is still surfaced" "$OUT" "$SID_S"
assert_hasnt "but no wake will run it" "$OUT" "echo --resume $SID_S"

echo ""
echo "── [7] a bounded list states what it left out ────────────────────────"
_t new-window -t alpha:3 -n wide -c /tmp
i=1
while [ "$i" -lt 15 ]; do
  _t split-window -d -t alpha:3 -c /tmp >/dev/null 2>&1 || break
  _t select-layout -t alpha:3 tiled >/dev/null 2>&1
  i=$((i + 1))
done
WID3="$(_t display-message -p -t alpha:3 '#{window_id}')"
NP="$(_t list-panes -t alpha:3 -F x 2>/dev/null | wc -l | tr -d ' ')"
rm -rf "$W"; mkdir -p "$W"
_list > "$W/inv" 2>/dev/null
OUT="$(_preview "$WID3" window AWAKE - "$WID3" alpha:3 wide)"
if [ "$NP" -gt 14 ]; then
  assert_eq  "the cap holds the list at 14 rows" "$(_plan_rows "$OUT")" "14"
  assert_has "and the remainder is stated" "$OUT" "$((NP - 14)) more pane"
else
  no "the fixture could not open more than 14 panes (got $NP)"
fi

echo ""
echo "  Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
