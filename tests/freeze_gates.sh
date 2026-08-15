#!/usr/bin/env bash
# freeze_gates.sh — the four refusal gates of `cc_freeze.sh freeze` (§3.1).
#
#   G1/G2  the per-PROCESS sid gate (§3.1.5): more live claude/claudish
#          processes than resolved sids => REFUSED, exit 3, nothing written and
#          nothing killed — and `--force` does NOT override it, ever.
#   G3     the ;DUP= refusal (§3.1.6): a sid that is not attributable to one
#          process is no sid at all, and the ;DUP= marker must never reach a
#          state file.
#   G4     exec-token classification (§3.1.8): token-exact, on the BASENAME —
#          a `claude` directory in a path must not launder `vim`, and a binary
#          merely starting with "vim" is not `vim`.
#   G5     the stale-capture abort (§3.1.7): the kill set is the CAPTURED set,
#          re-verified immediately before the first signal. Any discrepancy =>
#          state file deleted, REFUSED stale-capture, exit 3, nothing killed.
#   G6     a `❄` title with no verified state file (§3.1.1) => FAILED, exit 2,
#          and NOTHING is killed.
#
# How the worlds are built:
#   * G1-G4 inject a process table with CC_PS_SNAPSHOT (§3, test escapes), so
#     classification and kill-planning are exercised with no real trees. Every
#     fabricated pid is >= 900001, which is above macOS's PID_MAX (99999), so a
#     stray kill can never reach a real process.
#   * G5 uses REAL trees, and reaches the resume-from-kill path deterministically
#     via CC_FAIL_AFTER=persist: state durable, nothing killed, window intact.
#     Mutating the world between the two runs is what makes the capture stale —
#     with a no-mutation POSITIVE CONTROL, so "REFUSED" cannot pass for the
#     wrong reason.
#
# THE FIXTURE RULE (this file is where the exceptions live):
#   A pane that must be FREEZABLE is a BARE INTERACTIVE SHELL — no `-c`, no
#   operand, no work — because §H4 classifies a shell carrying an operand as
#   SHELL-WITH-WORK => UNSAFE. So does `sleep`, and so does anything else not in
#   the SHELL/WRAPPER/CLAUDE/MCP set: H4's last row is `anything else =>
#   UNSAFE:<base>`. Scaffolding parked on `sh -c '…'` or holding a `sleep` makes
#   every freeze `REFUSED … unsafe-process:` and tests nothing.
#   An UNSAFE fixture is used ONLY where being refused is the assertion — 4a/4c
#   (`vim`), 4b (`vimrc-sync`), 4e (`vim` under --force). Those are the point of
#   G4 and they stay exactly as they are.
#
# Isolation: own tmux socket, `-f /dev/null` on EVERY tmux invocation, all state
# under /tmp, CC_TEST=1.
#
# Usage: bash tests/freeze_gates.sh   (exit 0 = pass)

set -uo pipefail

# ── RESURRECT SAVE-SIDE ISOLATION ────────────────────────────────────────────
# RESURRECT_FILE redirects resurrect READS. Only @resurrect-dir redirects its
# WRITES. A test that triggers a save without setting it deposits fixture
# snapshots in the user's live resurrect directory and can leave `last`
# pointing at one. See tests/lib/resurrect_guard.sh for the measured damage.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed work legacy alpha beta lvl cA cB cC cD cE

SOCKET="ccgt$$"
TD="/tmp/ccgt-$$"
FD="$TD/frozen"
PD="$TD/panes"
LD="$TD/launch"
QD="$TD/pending"
RD="$TD/resurrect"
BIN="$TD/bin"
FIX="$TD/fix"
LOG="$TD/cc.log"
FLOG="$TD/cc-freeze.log"
PSF="$TD/ps.table"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
FREEZE="$SCRIPT_DIR/cc_freeze.sh"

TMUX_CMD_STR="tmux -L $SOCKET -f /dev/null"
NOW="$(date +%s)"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
no()  { echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail+1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$2], want [$3]"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then ok "$1"; else no "$1" "got [$2], want anything else"; fi; }
_trunc() { printf '%s' "$1" | tr '\n' '/' | cut -c1-220; }
assert_has() { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "want [$3]; got [$(_trunc "$2")]" ;; esac; }

# ── PRE-FLIGHT GUARD ─────────────────────────────────────────────────────────
case "$SOCKET" in
  default|""|*/*|*\ *) echo "ABORT: unsafe socket name [$SOCKET]"; exit 1 ;;
  ccgt*) ;;
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

if [ ! -f "$FREEZE" ]; then
  echo "  FAIL: required script missing: $FREEZE"
  echo ""; echo "  Results: 0 passed, 1 failed"; exit 1
fi

ln -s /bin/sh "$BIN/op"
ln -s /bin/sh "$BIN/claude"
# G5 needs a tree that does NOT churn: `while :; do sleep 5; done` forks a new
# pid every 5 s, and a new pid in a pane's descendant set is itself a
# stale-capture trigger (§3.1.7), which would make the positive control flap.
# It also needs a tree that is entirely SAFE, or G5 refuses for a G4 reason and
# the stale-capture rail is never reached. Both are satisfied by a leaf that
# blocks on open(2) of a writer-less FIFO: it never returns, it forks no child,
# and it is a shell — not a `sleep`, which H4 classifies UNSAFE. The trailing
# `:` stops sh exec-ing the last command away, so the tree keeps its depth:
# pane -> shell -> op(wrapper) -> claude, claude a GRANDCHILD.
mkfifo "$FIX/hold.fifo"
printf 'read _x < "%s/hold.fifo"\n' "$FIX" > "$FIX/hold.sh"
printf '"%s/claude" "%s/hold.sh"\n:\n' "$BIN" "$FIX" > "$FIX/oprun.sh"
CLAUDE_TREE_CMD="\"$BIN/op\" \"$FIX/oprun.sh\""

_t new-session -d -s _seed -c /tmp
_t set-option -g base-index 1 >/dev/null
_t set-option -g pane-base-index 1 >/dev/null
_t set-option -g default-shell /bin/sh >/dev/null
# Every pane is the bare interactive shell the classifier must accept. `sh -i`
# and not a LOGIN shell, so no ~/.profile of the user's is sourced into a test
# pane; ENV=/dev/null closes the -i startup file too.
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

# work:1..8 hold injected worlds (one parked shell each);
# work:9..10 hold REAL claude trees for the stale-capture case;
# work:11 is the bogus-tombstone case.
_t new-session -d -s work -n g1-sidgate    -c /tmp
wi=1
for n in g3-dup-owner g3-dup-target g4-vim g4-prefix g4-pathlaunder g4-safe g4-claudish; do
  wi=$((wi + 1))
  _t new-window -t "work:$wi" -n "$n" -c /tmp
done
# Both panes of each G5 window are bare interactive shells with no children:
# stable, freezable, and able to fork a new descendant on demand via send-keys,
# which is how the capture is made stale WITHOUT killing anything. The Claude
# tree is grown inside pane 1 below.
_t new-window -t work:9 -n g5-stale -c /tmp
_t split-window -t work:9 -c /tmp
_t new-window -t work:10 -n g5-control -c /tmp
_t split-window -t work:10 -c /tmp
_t new-window -t work:11 -n g6-orphan -c /tmp
_t kill-session -t _seed

NS="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NS" != "1" ]; then echo "ABORT: expected 1 session on the test socket, found $NS"; exit 1; fi
NW="$(_t list-windows -t work | wc -l | tr -d ' ')"
if [ "$NW" != "11" ]; then echo "ABORT: expected 11 windows, found $NW"; exit 1; fi

_descendants() {
  ps -axo pid=,ppid= | awk -v r="$1" '
    { pid[NR]=$1; pp[$1]=$2; n=NR }
    END { q[1]=r; c=1; h=1
          while (h <= c) { cur=q[h]; h++
            for (i=1; i<=n; i++) if (pp[pid[i]] == cur) { c++; q[c]=pid[i] } }
          for (i=2; i<=c; i++) print q[i] }'
}
_pid_cmd() { ps -p "$1" -o command= 2>/dev/null; }
_count_lines() { grep -c . "$1" 2>/dev/null | tr -d ' '; }
_count_alive() { local n=0 p; while IFS= read -r p; do [ -z "$p" ] && continue
    kill -0 "$p" 2>/dev/null && n=$((n+1)); done < "$1"; printf '%s' "$n"; }
_list_alive() { local p; while IFS= read -r p; do [ -z "$p" ] && continue
    kill -0 "$p" 2>/dev/null && printf '%s ' "$p"; done < "$1"; }
_pane_pid() { _t list-panes -t "$1" -F '#{pane_pid}' | head -1; }
_pane_count() { _t list-panes -t "$1" 2>/dev/null | wc -l | tr -d ' '; }
_frozen_opt() { _t show-options -w -t "$1" -v @cc-frozen 2>/dev/null || true; }
# THE ATOM IS A PANE: the claim moved from the window option to the PANE option,
# so a claim assertion made with -w now passes vacuously on every implementation.
_pane_frozen_opt() { _t show-options -p -t "$1" -v @cc-frozen 2>/dev/null || true; }
_state_count() { ls "$FD"/*/*.state 2>/dev/null | wc -l | tr -d ' '; }
_state_path() { ls "$FD"/*/"$1.state" 2>/dev/null | head -1; }
_field() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NF>=2 { print $n; exit }'; }
_titles() { _t list-panes -t "$1" -F '#{pane_title}' 2>/dev/null | tr '\n' '|'; }
# stdout is one row per PANE, plus container summary rows (WINDOW / SESSION).
_pane_rows() { printf '%s\n' "$1" | awk -F'\t' 'NF>=2 && $1!="WINDOW" && $1!="SESSION"'; }
_row_for()   { printf '%s\n' "$1" | awk -F'\t' -v t="$2" 'NF>=2 && $2==t { print; exit }'; }
_verbs()     { _pane_rows "$1" | awk -F'\t' '{print $1}' | sort | tr '\n' ' '; }
_keys_of()   { _pane_rows "$1" | awk -F'\t' '$3!="-" {print $3}' | sort | tr '\n' ' '; }

_freeze() { # runs against REAL processes
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_NO_SAVE=1 bash "$FREEZE" "$@"
}
_freeze_ps() { # runs against the INJECTED process table
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_NO_SAVE=1 CC_PS_SNAPSHOT="$PSF" bash "$FREEZE" "$@"
}

# ── Grow G5's real Claude trees inside the bare shells of w9/w10 ─────────────
# The needle is assembled INSIDE awk from two arguments so the matcher's own
# argv never contains it: `ps | grep "$BIN/claude "` self-matches (ps sees the
# grep it is piped into) and reports a claude that does not exist. The send is
# retried, not merely polled — keys typed before the pane's shell has drawn its
# first prompt are lost, and waiting does not bring them back.
_pane_id_at() { _t list-panes -t "work:$1" -F '#{pane_index} #{pane_id}' 2>/dev/null \
                 | awk -v i="$2" '$1==i { print $2; exit }'; }
_claude_procs() { ps -axo pid=,command= \
    | awk -v b="$BIN" -v s="/claude " 'index($0, b s) { n++ } END { print n+0 }'; }
_grow_claude_tree() { # <pane_id> <total claude procs expected once it is up>
  local _try
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ "$(_claude_procs)" -ge "$2" ] && return 0
    case "$_try" in 1|5|9) _t send-keys -t "$1" "$CLAUDE_TREE_CMD" Enter ;; esac
    sleep 0.4
  done
  [ "$(_claude_procs)" -ge "$2" ]
}
G9_PANE="$(_pane_id_at 9 1)"; G10_PANE="$(_pane_id_at 10 1)"
if [ -z "$G9_PANE" ] || [ -z "$G10_PANE" ]; then
  echo "ABORT: could not resolve pane 1 of work:9 / work:10"; exit 1
fi
_grow_claude_tree "$G9_PANE"  1 || echo "  (warning: w9 claude tree did not come up)"
_grow_claude_tree "$G10_PANE" 2 || echo "  (warning: w10 claude tree did not come up)"

# ── The injected world ───────────────────────────────────────────────────────
# One table for every window, so a cross-window claim (the ;DUP= case) is
# visible. Fabricated pids are 9000xx — above macOS's PID_MAX, so `kill` on one
# can never reach a live process.
P1="$(_pane_pid work:1)";  P2="$(_pane_pid work:2)";  P3="$(_pane_pid work:3)"
P4="$(_pane_pid work:4)";  P5="$(_pane_pid work:5)";  P6="$(_pane_pid work:6)"
P7="$(_pane_pid work:7)";  P8="$(_pane_pid work:8)"
for v in P1 P2 P3 P4 P5 P6 P7 P8; do
  eval "pv=\$$v"
  if [ -z "${pv:-}" ]; then echo "ABORT: could not read a pane pid for $v"; exit 1; fi
done

SID_DUP="dddddddd-1111-4111-8111-dddddddddddd"
SID_ONE="11111111-1111-4111-8111-111111111111"
SID_TWO="22222222-2222-4222-8222-222222222222"
SID_CLDH="33333333-3333-4333-8333-333333333333"

_write_ps_table() {
  # Every case varies exactly ONE thing: the leaf process. The pane process and
  # the intermediate are always a bare, unambiguous shell, so a refusal can only
  # be attributed to the leaf. (The `pane -> shell -> wrapper -> claude`
  # GRANDCHILD shape is exercised for real, with real kills, in G5 below and in
  # freeze_tombstone.sh / thaw_roundtrip.sh.)
  {
    for pp in "$P1" "$P2" "$P3" "$P4" "$P5" "$P6" "$P7" "$P8"; do
      printf '%s 1 /bin/zsh\n' "$pp"
    done
    # work:1 — TWO claude processes under one shell: the per-process sid gate
    printf '900100 %s /bin/zsh\n' "$P1"
    printf '900101 900100 /Users/jack/.local/bin/claude --dangerously-skip-permissions\n'
    printf '900102 900100 /Users/jack/.local/bin/claude --dangerously-skip-permissions\n'
    # work:2 / work:3 — one claude each, both claiming the SAME session id
    printf '900200 %s /bin/zsh\n' "$P2"
    printf '900201 900200 /Users/jack/.local/bin/claude\n'
    printf '900300 %s /bin/zsh\n' "$P3"
    printf '900301 900300 /Users/jack/.local/bin/claude\n'
    # work:4 — vim: the canonical data-loss process (AC7)
    printf '900400 %s /bin/zsh\n' "$P4"
    printf '900401 900400 /usr/bin/vim /tmp/notes.txt\n'
    # work:5 — token exactness: a basename that merely STARTS WITH vim
    printf '900500 %s /bin/zsh\n' "$P5"
    printf '900501 900500 /opt/local/bin/vimrc-sync --watch\n'
    # work:6 — a "claude" DIRECTORY in the path must not launder vim
    printf '900600 %s /bin/zsh\n' "$P6"
    printf '900601 900600 /Users/jack/claude/bin/vim /tmp/notes.txt\n'
    # work:7 — shells and nothing else: the SAFE positive control.
    # Not a `sleep`: H4's last row is `anything else => UNSAFE:<base>`, and
    # `sleep` is not a shell, a wrapper, Claude or an MCP helper, so a sleeping
    # leaf is refused exactly like `vim` and this control would prove the
    # opposite of what it is for. A login shell (leading `-`) and an `-l` shell
    # are used, because that is what the live machine's panes actually are and
    # H4 explicitly allows both.
    printf '900700 %s /bin/zsh\n' "$P7"
    printf '900701 900700 -zsh\n'
    printf '900702 900701 /bin/sh -l\n'
    # work:8 — claudish behind an interpreter prefix, carrying replay flags
    printf '900800 %s /bin/zsh\n' "$P8"
    printf '900801 900800 /usr/local/bin/node /Users/jack/.bun/bin/claudish --model cx@gpt-5.6-sol -d\n'
  } > "$PSF"
}
_write_ps_table

echo "[0] PREMISE: the injected world is what the gates will see"
assert_eq "one parked pane per injected window" \
  "$(for w in 1 2 3 4 5 6 7 8; do _pane_count "work:$w"; done | sort -u | tr '\n' ' ')" "1 "
assert_eq "no window is frozen yet" "$(_state_count)" "0"
if [ -s "$PSF" ]; then ok "process table written ($(_count_lines "$PSF") rows)"
else no "process table written"; fi

# ── G1: the per-process sid gate ─────────────────────────────────────────────
echo ""
echo "[1] G1: two live claude processes, one resolvable sid -> REFUSED (§3.1.5)"
rm -f "$PD/by-pid/"*.session-id
echo "$SID_ONE" > "$PD/by-pid/900101.session-id"
BEFORE_STATES="$(_state_count)"
OUT="$(_freeze_ps freeze --no-save work:1 2>"$TD/e1")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "exit code 3 (a decision, not an error)" "$RC" "3"
assert_eq "verb is REFUSED"                        "$(_field "$OUT" 1)" "REFUSED"
assert_eq "reason is no-sid-for-live-claude"       "$(_field "$OUT" 6)" "no-sid-for-live-claude"
assert_eq "nothing was written"                    "$(_state_count)" "$BEFORE_STATES"
assert_eq "the window is untouched (1 pane)"       "$(_pane_count work:1)" "1"
assert_eq "no @cc-frozen claim was set"            "$(_frozen_opt work:1)" ""

# ── G2: --force must never override the sid gate ─────────────────────────────
echo ""
echo "[2] G2: --force does NOT override the sid gate, ever (§3.1.5)"
OUT="$(_freeze_ps freeze --no-save --force work:1 2>"$TD/e2")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "still exit 3 under --force"       "$RC" "3"
assert_eq "still REFUSED under --force"      "$(_field "$OUT" 1)" "REFUSED"
assert_eq "still no-sid-for-live-claude"     "$(_field "$OUT" 6)" "no-sid-for-live-claude"
assert_eq "still nothing written"            "$(_state_count)" "$BEFORE_STATES"
assert_eq "still 1 pane"                     "$(_pane_count work:1)" "1"

# Positive control: the gate is satisfiable — otherwise "REFUSED" above proves
# nothing about the gate and everything about the fixture.
echo ""
echo "[2b] G1 POSITIVE CONTROL: give the second process its own sid -> not refused"
echo "$SID_TWO" > "$PD/by-pid/900102.session-id"
OUT="$(CC_NO_KILL=1 _freeze_ps freeze --no-save work:1 2>"$TD/e2b")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_ne "not REFUSED once every process has a sid" "$(_field "$OUT" 1)" "REFUSED"
assert_eq "exit code 0"                              "$RC" "0"
assert_eq "stdout sid count is 2"                    "$(_field "$OUT" 5)" "2"
KEY1="$(_field "$OUT" 3)"
SF1="$(_state_path "$KEY1")"
if [ -n "$SF1" ] && [ -s "$SF1" ]; then
  assert_eq "state file records 2 sids (one per line)" \
    "$(awk -F'\t' '$1=="sid"' "$SF1" | wc -l | tr -d ' ')" "2"
  assert_eq "state file records claude_procs 2 (the gate's denominator)" \
    "$(awk -F'\t' '$1=="claude_procs" {print $2}' "$SF1")" "2"
else
  no "state file written for the satisfied gate" "no state file for key [$KEY1]"
fi

# ── G3: the ;DUP= refusal ────────────────────────────────────────────────────
echo ""
echo "[3] G3: one session id claimed by two live processes -> REFUSED dup (§3.1.6)"
rm -f "$PD/by-pid/"*.session-id
echo "$SID_DUP" > "$PD/by-pid/900201.session-id"
echo "$SID_DUP" > "$PD/by-pid/900301.session-id"
BEFORE_STATES="$(_state_count)"
OUT="$(_freeze_ps freeze --no-save work:3 2>"$TD/e3")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
REASON="$(_field "$OUT" 6)"
assert_eq "exit code 3"                    "$RC" "3"
assert_eq "verb is REFUSED"                "$(_field "$OUT" 1)" "REFUSED"
assert_has "reason names the duplicate"    "$REASON" "no-sid-for-live-claude:dup="
case "$REASON" in
  no-sid-for-live-claude:dup=?*) ok "the reason names the owner (${REASON#*dup=})"; pass=$pass ;;
  *) no "the reason names the owner" "reason=[$REASON]" ;;
esac
assert_eq  "nothing was written"           "$(_state_count)" "$BEFORE_STATES"
assert_eq  "the window is untouched"       "$(_pane_count work:3)" "1"
assert_eq  "no @cc-frozen claim was set"   "$(_frozen_opt work:3)" ""
assert_eq  "--force does not smuggle it through" \
  "$(_field "$(_freeze_ps freeze --no-save --force work:3 2>/dev/null)" 1)" "REFUSED"
# A ;DUP= string must never be able to enter the store at all.
DUPLEAK="$(grep -rl 'DUP=' "$FD" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "no file in the store contains a ;DUP= marker" "$DUPLEAK" "0"

# ── G4: exec-token classification ────────────────────────────────────────────
echo ""
echo "[4] G4: classification is token-exact, on the BASENAME (§3.1.8)"
rm -f "$PD/by-pid/"*.session-id
BEFORE_STATES="$(_state_count)"

# 4a — the canonical unsafe process (AC7's example)
OUT="$(_freeze_ps freeze --no-save work:4 2>/dev/null)"; RC=$?
printf '    4a vim            exit=%s [%s]\n' "$RC" "$OUT"
assert_eq "4a exit code 3"              "$RC" "3"
assert_eq "4a verb is REFUSED"          "$(_field "$OUT" 1)" "REFUSED"
assert_eq "4a reason is unsafe-process:vim" "$(_field "$OUT" 6)" "unsafe-process:vim"
assert_eq "4a nothing written"          "$(_state_count)" "$BEFORE_STATES"
assert_eq "4a window untouched"         "$(_pane_count work:4)" "1"

# 4b — token exactness: "vimrc-sync" is NOT "vim". Whatever the verdict, the
# reason may never name a token the process does not have.
OUT="$(_freeze_ps freeze --no-save work:5 2>/dev/null)"; RC=$?
REASON="$(_field "$OUT" 6)"
printf '    4b vimrc-sync     exit=%s [%s]\n' "$RC" "$OUT"
assert_ne "4b never classified as the token 'vim'" "$REASON" "unsafe-process:vim"
case "$(_field "$OUT" 1)" in
  REFUSED) assert_has "4b if refused, the reason names the real basename" "$REASON" "vimrc-sync" ;;
  *) ok "4b not refused as 'vim' (verb $(_field "$OUT" 1))" ;;
esac

# 4c — a "claude" directory in the path must not launder an unsafe binary
OUT="$(_freeze_ps freeze --no-save work:6 2>/dev/null)"; RC=$?
printf '    4c claude/bin/vim exit=%s [%s]\n' "$RC" "$OUT"
assert_eq "4c exit code 3"                   "$RC" "3"
assert_eq "4c reason is unsafe-process:vim"  "$(_field "$OUT" 6)" "unsafe-process:vim"
assert_ne "4c NOT mistaken for a claude process" "$(_field "$OUT" 6)" "no-sid-for-live-claude"

# 4d — safe descendants only: the classifier must let this through, or every
#      assertion above is just "freeze always refuses".
OUT="$(CC_NO_KILL=1 _freeze_ps freeze --no-save work:7 2>/dev/null)"; RC=$?
printf '    4d shells only    exit=%s [%s]\n' "$RC" "$OUT"
assert_ne "4d a shell-only window is NOT refused" "$(_field "$OUT" 1)" "REFUSED"
assert_eq "4d exit code 0"                        "$RC" "0"
assert_eq "4d recorded sid count is 0"            "$(_field "$OUT" 5)" "0"

# 4e — --force DOES override unsafe-process (§3.1.8: "unless --force"),
#      which is exactly the gate --force must NOT override in G2.
OUT="$(CC_NO_KILL=1 _freeze_ps freeze --no-save --force work:4 2>/dev/null)"; RC=$?
printf '    4e vim + --force  exit=%s [%s]\n' "$RC" "$OUT"
assert_ne "4e --force overrides unsafe-process" "$(_field "$OUT" 1)" "REFUSED"
assert_eq "4e exit code 0 under --force"        "$RC" "0"

# 4f — an interpreter prefix resolves to the script: `node …/claudish` is
#      claudish, not `node`.
echo "$SID_CLDH" > "$PD/by-pid/900801.session-id"
OUT="$(CC_NO_KILL=1 _freeze_ps freeze --no-save work:8 2>/dev/null)"; RC=$?
printf '    4f node claudish  exit=%s [%s]\n' "$RC" "$OUT"
assert_ne "4f claudish behind an interpreter is not refused" "$(_field "$OUT" 1)" "REFUSED"
assert_eq "4f its sid is counted"                            "$(_field "$OUT" 5)" "1"
KEY8="$(_field "$OUT" 3)"
SF8="$(_state_path "$KEY8")"
if [ -n "$SF8" ] && [ -s "$SF8" ]; then
  assert_eq "4f recorded with CLASS=claudish" \
    "$(awk -F'\t' '$1=="sid" { for (i=1;i<=NF;i++) if (index($i,";CLASS=")==1) print substr($i,8) }' "$SF8")" \
    "claudish"
else
  no "4f state file written" "no state file for key [$KEY8]"
fi

# 4g — the sid gate is per CLAUDE/CLAUDISH PROCESS (§3.1.5, H1(a)): "every
#      non-MCP-pruned claude/claudish process found in the window's descendant
#      sets must map to a recorded sid". A claudish with NO sid is therefore a
#      refusal, and the refusal must happen with NOTHING written and NOTHING
#      killed. This is the direction that loses data if it is wrong: a claudish
#      counted as zero live Claudes satisfies `sid_count == claude_procs` at
#      0 == 0, and the freeze proceeds to kill a live session whose id was never
#      recorded — exactly the loss H1 exists to make impossible.
rm -f "$PD/by-pid/"*.session-id
BEFORE_STATES="$(_state_count)"
OUT="$(_freeze_ps freeze --no-save work:8 2>/dev/null)"; RC=$?
printf '    4g claudish w/o sid exit=%s [%s]\n' "$RC" "$OUT"
assert_eq "4g a claudish with no sid is REFUSED" "$(_field "$OUT" 1)" "REFUSED"
assert_eq "4g exit code 3"                       "$RC" "3"
assert_eq "4g reason is no-sid-for-live-claude"  "$(_field "$OUT" 6)" "no-sid-for-live-claude"
assert_eq "4g nothing was written"               "$(_state_count)" "$BEFORE_STATES"
assert_eq "4g the window is untouched"           "$(_pane_count work:8)" "1"
assert_eq "4g no @cc-frozen claim was set"       "$(_frozen_opt work:8)" ""

# ── G5: the stale-capture abort ──────────────────────────────────────────────
echo ""
echo "[5] G5: the kill set is the CAPTURED set, re-verified before the first signal (§3.1.7)"

_tree_of_window() { # <target> <outfile>
  : > "$2"
  local pp
  while IFS= read -r pp; do
    [ -z "$pp" ] && continue
    printf '%s\n' "$pp" >> "$2"
    _descendants "$pp" >> "$2"
  done < <(_t list-panes -t "$1" -F '#{pane_pid}')
  sort -u "$2" -o "$2"
}
_claude_of_window() { # <target> <outfile>
  : > "$2"
  local p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$(_pid_cmd "$p")" in "$BIN/claude"*) printf '%s\n' "$p" >> "$2" ;; esac
  done < "$1"
}

rm -f "$PD/by-pid/"*.session-id
for _try in 1 2 3 4 5 6 7 8 9 10; do
  _tree_of_window work:9  "$TD/t9";  _claude_of_window "$TD/t9"  "$TD/c9"
  _tree_of_window work:10 "$TD/t10"; _claude_of_window "$TD/t10" "$TD/c10"
  [ "$(_count_lines "$TD/c9")" = "1" ] && [ "$(_count_lines "$TD/c10")" = "1" ] && break
  sleep 0.4
done
assert_eq "w9 has exactly one real claude process"  "$(_count_lines "$TD/c9")"  "1"
assert_eq "w10 has exactly one real claude process" "$(_count_lines "$TD/c10")" "1"
assert_eq "every w9 pid is ALIVE before we start" \
  "$(_count_alive "$TD/t9")" "$(_count_lines "$TD/t9")"
assert_eq "every w10 pid is ALIVE before we start" \
  "$(_count_alive "$TD/t10")" "$(_count_lines "$TD/t10")"
C9="$(head -1 "$TD/c9")"; C10="$(head -1 "$TD/c10")"
[ -n "$C9" ] && echo "$SID_ONE" > "$PD/by-pid/$C9.session-id"
[ -n "$C10" ] && echo "$SID_TWO" > "$PD/by-pid/$C10.session-id"

# 5a — the half-state: durable capture, nothing killed (FR1.7 / D3 ordering)
echo ""
echo "[5a] CC_FAIL_AFTER=persist: state is durable BEFORE anything is killed"
OUT="$(CC_FAIL_AFTER=persist _freeze freeze --no-save work:10 2>/dev/null)"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
_state_scalar() { awk -F'\t' -v k="$2" '$1==k { print $2; exit }' "$1" 2>/dev/null; }
# The atom is a pane, so a 2-pane window leaves TWO half-states, one per pane.
HALF_KEYS="$TD/half_keys"; : > "$HALF_KEYS"
for f in "$FD"/*/*.state; do
  [ -f "$f" ] || continue
  [ "$(_state_scalar "$f" window_index)" = "10" ] || continue
  printf '%s\n' "$(_state_scalar "$f" key)" >> "$HALF_KEYS"
done
sort -o "$HALF_KEYS" "$HALF_KEYS"
if [ "$(_count_lines "$HALF_KEYS")" = "2" ]; then
  ok "both captures are on disk after the injected failure"
else
  no "both captures are on disk after the injected failure" \
     "found $(_count_lines "$HALF_KEYS") state file(s) for window 10 — the write-ahead ordering is not observable"
fi
assert_eq "NOTHING was killed (every w10 pid still alive)" \
  "$(_count_alive "$TD/t10")" "$(_count_lines "$TD/t10")"
assert_eq "the window still has both panes" "$(_pane_count work:10)" "2"
# §3.1.1's resume-from-kill branch can only exist if the half-state is CLAIMED:
# a state entry is inert until something live carries its key (§7, @cc-frozen).
# Under the pane atom that claim is a PANE option, and each entry must be claimed
# by the pane it captured — not by the window, and not by a sibling.
BADCLAIM=0
while IFS= read -r k; do
  [ -z "$k" ] && continue
  sf="$(_state_path "$k")"
  p="$(_state_scalar "$sf" pane_id)"
  if [ -z "$p" ] || [ "$(_pane_frozen_opt "$p")" != "$k" ]; then
    BADCLAIM=$((BADCLAIM+1))
    echo "        entry $k names pane [$p] whose claim is [$(_pane_frozen_opt "${p:-%none}")]"
  fi
done < "$HALF_KEYS"
assert_eq "every half-state is claimed by the PANE it captured, so it can be resumed" "$BADCLAIM" "0"

# 5b — POSITIVE CONTROL: with the world unchanged, the resume completes.
echo ""
echo "[5b] POSITIVE CONTROL: unchanged world -> the freeze resumes from the kill step"
STATES_BEFORE_RESUME="$(_state_count)"
LAYOUT10_BEFORE="$(_t display-message -p -t work:10 '#{window_layout}')"
OUT="$(_freeze freeze --no-save work:10 2>/dev/null)"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "every pane reports FROZE (not stale-capture)" "$(_verbs "$OUT")" "FROZE FROZE "
assert_eq "exit code 0"                       "$RC" "0"
# The pane atom never restructures a window: the freeze respawns each pane in
# place, so the pane count and the layout are unchanged and every pane is a
# tombstone. "Collapsed to 1 pane" was the window model and would now mean the
# freeze destroyed a pane.
assert_eq "the window was NOT restructured — both panes remain" "$(_pane_count work:10)" "2"
assert_eq "its layout is byte-identical"      "$(_t display-message -p -t work:10 '#{window_layout}')" "$LAYOUT10_BEFORE"
assert_eq "both panes are tombstones" \
  "$(_t list-panes -t work:10 -F '#{pane_title}' | grep -vc "^$(printf '\xe2\x9d\x84') FROZEN " | tr -d ' ')" "0"
# "FROZE" alone cannot tell a RESUME from a fresh re-capture — both end in a
# tombstone and both say FROZE. The mechanism is the key: §3.1.1's branch resumes
# "using the persisted capture", so it must reuse that capture's key. A new key
# means the half-state was abandoned, not resumed, and the persisted capture —
# which holds session ids and which §9 never garbage-collects — is orphaned in
# the store, where D1 makes it inert forever.
if [ "$(_count_lines "$HALF_KEYS")" = "2" ]; then
  assert_eq "the resume reused the PERSISTED captures' keys, both of them" \
    "$(_keys_of "$OUT")" "$(tr '\n' ' ' < "$HALF_KEYS")"
  assert_eq "no second state file was minted for either pane" \
    "$(_state_count)" "$STATES_BEFORE_RESUME"
fi
for _w in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(_count_alive "$TD/t10")" = "0" ] && break
  sleep 0.3
done
assert_eq "every captured w10 pid is dead" "$(_count_alive "$TD/t10")" "0"

# 5c — the abort: mutate the world between capture and kill.
echo ""
echo "[5c] MUTATED WORLD: a recorded pid disappears -> REFUSED stale-capture"
_tree_of_pane() { # <pane id> <outfile>: that pane's pid AND every descendant
  local pp; pp="$(_t display-message -p -t "$1" '#{pane_pid}' 2>/dev/null)"
  : > "$2"; [ -z "$pp" ] && return 0
  printf '%s\n' "$pp" >> "$2"; _descendants "$pp" >> "$2"
  sort -u "$2" -o "$2"
}
# Stale-capture is decided PER PANE now — the re-verification compares each
# pane's own captured set against its own fresh descendant set — so the intruder
# is planted in one named pane and the assertions are made about THAT pane. Its
# sibling's capture is untouched and freezing it is the correct outcome, not a
# leak: asserting "nothing in the window was killed" would now be asserting a bug.
STALE_PANE="$(_t list-panes -t work:9 -F '#{pane_id}' | tail -1)"
CLEAN_PANE="$(_t list-panes -t work:9 -F '#{pane_id}' | head -1)"
_tree_of_pane "$STALE_PANE" "$TD/t9_stale"
_tree_of_pane "$CLEAN_PANE" "$TD/t9_clean"

OUT="$(CC_FAIL_AFTER=persist _freeze freeze --no-save work:9 2>/dev/null)"; RC=$?
printf '    persist exit=%s stdout=[%s]\n' "$RC" "$OUT"
SF9=""
for f in "$FD"/*/*.state; do
  [ -f "$f" ] || continue
  [ "$(_state_scalar "$f" window_index)" = "9" ] || continue
  [ "$(_state_scalar "$f" pane_id)" = "$STALE_PANE" ] || continue
  SF9="$f"
done
if [ -n "$SF9" ]; then
  ok "the capture of the pane we are about to make stale is on disk"
else
  no "the capture of the pane we are about to make stale is on disk" \
     "no state entry naming $STALE_PANE"
fi
assert_eq "still nothing killed" "$(_count_alive "$TD/t9")" "$(_count_lines "$TD/t9")"

if [ -n "$SF9" ]; then
  STALE_KEY="$(_state_scalar "$SF9" key)"
  STATES_BEFORE="$(_state_count)"
  # Make the capture stale WITHOUT killing anything: fork one new process inside
  # a pane, so the fresh descendant set of a pane pid now contains a pid that was
  # not in the captured set (§3.1.7's second clause). Nothing dies, nothing
  # cascades, so "nothing was killed" afterwards is a real assertion.
  # The intruder is a child SHELL, not a `sleep`: a sleeping intruder would
  # classify UNSAFE (H4's last row), so the refusal could be an unsafe-process
  # verdict wearing stale-capture's name. A shell is unambiguously SAFE, which
  # leaves "a pid appeared that was not in the captured set" as the only
  # available reason to refuse.
  SH_PANE="$STALE_PANE"
  _t send-keys -t "$SH_PANE" '/bin/sh -i' Enter
  INTRUDER=""
  for _w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    _tree_of_window work:9 "$TD/t9b"
    INTRUDER="$(comm -13 "$TD/t9" "$TD/t9b" | head -1)"
    [ -n "$INTRUDER" ] && break
    sleep 0.3
  done
  if [ -n "$INTRUDER" ]; then
    ok "a new process really joined the window's tree (pid $INTRUDER: $(_pid_cmd "$INTRUDER" | cut -c1-30))"
  else
    no "a new process really joined the window's tree" "send-keys forked nothing — the world is not stale"
  fi
  assert_eq "every ORIGINAL w9 pid is still ALIVE before the second run" \
    "$(_count_alive "$TD/t9")" "$(_count_lines "$TD/t9")"

  OUT="$(_freeze freeze --no-save work:9 2>/dev/null)"; RC=$?
  printf '    resume  exit=%s stdout=[%s]\n' "$RC" "$OUT"
  STALE_ROW="$(_row_for "$OUT" "work:9.$(_t display-message -p -t "$STALE_PANE" '#{pane_index}')")"
  CLEAN_ROW="$(_row_for "$OUT" "work:9.$(_t display-message -p -t "$CLEAN_PANE" '#{pane_index}')")"
  assert_eq "the stale pane's verb is REFUSED"   "$(_field "$STALE_ROW" 1)" "REFUSED"
  assert_eq "its reason is stale-capture"        "$(_field "$STALE_ROW" 6)" "stale-capture"
  assert_eq "a refused pane is given no key"     "$(_field "$STALE_ROW" 3)" "-"
  # The sibling's captured set is unchanged, so it is not stale and freezing it is
  # correct. Asserting otherwise would demand that one pane's intruder veto another
  # pane's freeze, which is the window model reappearing under a new name.
  assert_eq "its untouched sibling still freezes" "$(_field "$CLEAN_ROW" 1)" "FROZE"
  assert_ne "the refusal is not reported as success" "$RC" "0"
  assert_eq "the stale entry was deleted"        "$(_state_path "$STALE_KEY")" ""
  assert_eq "one entry fewer in the store"       "$(_state_count)" "$((STATES_BEFORE - 1))"
  assert_eq "NOTHING in the stale pane was killed: every original pid is still alive" \
    "$(_count_alive "$TD/t9_stale")" "$(_count_lines "$TD/t9_stale")"
  assert_eq "the intruder was not killed either" \
    "$(kill -0 "${INTRUDER:-999999}" 2>/dev/null && echo alive || echo dead)" "alive"
  assert_eq "the window still has both panes" "$(_pane_count work:9)" "2"
  assert_eq "the refused pane carries no @cc-frozen claim" "$(_pane_frozen_opt "$STALE_PANE")" ""
  assert_hasnt "and it wears no tombstone title" \
    "$(_t display-message -p -t "$STALE_PANE" '#{pane_title}')" "$(printf '\xe2\x9d\x84') FROZEN"
  assert_ne "the pane that DID freeze claims its key" "$(_pane_frozen_opt "$CLEAN_PANE")" ""
fi

# ── G6: a tombstone title with no verified state file ────────────────────────
echo ""
echo "[6] G6: a ❄ title with no verified state file -> FAILED, exit 2, nothing killed (§3.1.1)"
_tree_of_window work:11 "$TD/t11"
assert_eq "every w11 pid is ALIVE before" "$(_count_alive "$TD/t11")" "$(_count_lines "$TD/t11")"
ORPHAN_PANE="$(_t list-panes -t work:11 -F '#{pane_id}' | head -1)"
ORPHAN_PID_BEFORE="$(_t display-message -p -t "$ORPHAN_PANE" '#{pane_pid}')"
_t select-pane -t "$ORPHAN_PANE" -T "$(printf '\xe2\x9d\x84 FROZEN 1700000000-nostat 1p/1s 2026-01-01')"
# The claim is a PANE option under the pane atom; a `-w` claim would be the
# legacy shape and would test the migration path, not this gate.
_t set-option -p -t "$ORPHAN_PANE" @cc-frozen "1700000000-nostat"
STATES_BEFORE="$(_state_count)"
OUT="$(_freeze freeze --no-save work:11 2>/dev/null)"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "verb is FAILED"                 "$(_field "$OUT" 1)" "FAILED"
assert_eq "exit code 2"                    "$RC" "2"
assert_eq "NOTHING was killed"             "$(_count_alive "$TD/t11")" "$(_count_lines "$TD/t11")"
assert_eq "the window is left exactly as found" "$(_pane_count work:11)" "1"
assert_eq "the pane was not even respawned" \
  "$(_t display-message -p -t "$ORPHAN_PANE" '#{pane_pid}')" "$ORPHAN_PID_BEFORE"
assert_eq "no state file was invented"     "$(_state_count)" "$STATES_BEFORE"
# §3.1.1 requires the half-state to be logged; it does not say WHERE, and
# §3.1.12's `<log>-freeze.log` is a side effect of a freeze that HAPPENED. This
# one did not happen, so both logs are legitimate destinations and the assertion
# is on the condition being recorded and naming the orphaned key — not on the
# implementation's choice of file.
assert_has "the condition is logged, naming the orphaned key" \
  "$(cat "$FLOG" "$LOG" 2>/dev/null)" "1700000000-nostat"

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
