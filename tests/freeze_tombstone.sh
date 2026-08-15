#!/usr/bin/env bash
# freeze_tombstone.sh — AC1, AC2, AC10 for `cc_freeze.sh freeze`.
#
# THE ATOM IS A PANE (design-delta-tree). A window freeze is a LOOP over that
# window's panes; nothing is collapsed and nothing is restructured. So:
#
#   AC1  3-pane window, 2 running Claude -> freeze -> EVERY pane is a tombstone,
#        the pane COUNT is unchanged, `window_layout` is unchanged, one state
#        file per pane records that pane (3 files, 2 session ids between them),
#        and the 3 original pane process trees are gone.
#   AC2  frozen window at index 2 of 4   -> the other 3 window indices are
#        unchanged, and so are this window's pane count and layout.
#   AC10 freeze twice                    -> the second call succeeds (ALREADY per
#        pane, exit 0) and changes nothing.
#
# WHY THE OLD ASSERTIONS WENT. This file used to assert "the window collapsed to
# exactly 1 pane" and "the window carries @cc-frozen". Both encoded the WINDOW
# model: a freeze collapsed N panes into one tombstone and replayed a recorded
# layout on thaw. Under the pane model the window is never restructured, so
# "1 pane" is now the assertion of a BUG (it would mean the freeze destroyed
# panes), and the claim rides on the PANE option, not the window option. The
# replacements are strictly stronger: pane count AND `window_layout` AND every
# `pane_id` must be byte-identical across the freeze, which is exactly what
# "respawn in place" means and is the property that makes layout replay
# unnecessary (delta: "respawning every pane leaves window_layout BYTE-IDENTICAL").
#
# Asserted against the API contract in architecture §3.1 + design-delta-tree and
# the on-disk state file format in §2.3 — never against any implementation detail.
#
# Two design rules this file obeys, both learned from false passes in this repo:
#   * "the processes are gone" is only meaningful after asserting they were
#     ALIVE. Every pid is iterated ONE PER LINE (`kill -0 "1 2 3"` always fails,
#     which reports every process dead and passes forever).
#   * the MECHANISM is asserted, not just the end state: the pane id survives
#     while the pane PID changes (that IS "respawned in place"), the tombstone
#     title, the recorded ;PID= tags, each state file's own counters and the
#     stdout TSV must all agree with each other and with the live server.
#
# Fixtures are fake: symlinks to /bin/sh carrying the argv[0] the classifier
# keys on, arranged as pane -> shell -> op(wrapper) -> claude, so `claude` is a
# GRANDCHILD exactly as `op run … -- claude` produces. No real Claude is run.
#
# THE FIXTURE RULE, and why an earlier version of this file had it backwards:
#   A pane that is expected to FREEZE must be a BARE INTERACTIVE SHELL — what
#   tmux gives a new pane when you send it no command. It must NOT be parked on
#   `sh -c '<work>'`, because §H4 classifies a shell carrying an operand as
#   SHELL-WITH-WORK => UNSAFE. That rail is deliberate and correct: Claude Code's
#   Bash tool runs commands through a shell with `-c`, so an in-flight tool call
#   is caught by its own parent and the pane refuses to freeze. Parking a
#   fixture on `sh -c` therefore makes EVERY freeze return
#   `REFUSED … unsafe-process:sh` and proves nothing about the tombstone.
#   It matches production, too: every real pane process on this machine is a
#   bare `/bin/zsh` or `-zsh`, for Claude panes and idle panes alike.
#   The unsafe path is exercised deliberately, where it is the point, in
#   tests/freeze_gates.sh and tests/freeze_pane_atom.sh — not smuggled in
#   through the scaffolding here.
#
# Isolation: own tmux socket, `-f /dev/null` on EVERY tmux invocation, every
# directory under /tmp, CC_TEST=1 so the implementation re-checks the contract.
#
# Usage: bash tests/freeze_tombstone.sh   (exit 0 = pass)

set -uo pipefail

# ── RESURRECT SAVE-SIDE ISOLATION ────────────────────────────────────────────
# RESURRECT_FILE redirects resurrect READS. Only @resurrect-dir redirects its
# WRITES. A test that triggers a save without setting it deposits fixture
# snapshots in the user's live resurrect directory and can leave `last`
# pointing at one. See tests/lib/resurrect_guard.sh for the measured damage.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed work legacy alpha beta lvl cA cB cC cD cE

SOCKET="ccft$$"
TD="/tmp/ccft-$$"
FD="$TD/frozen"
PD="$TD/panes"
LD="$TD/launch"
QD="$TD/pending"
RD="$TD/resurrect"
BIN="$TD/bin"
FIX="$TD/fix"
LOG="$TD/cc.log"
FLOG="$TD/cc-freeze.log"          # contract: ${LOG_FILE%.log}-freeze.log
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
FREEZE="$SCRIPT_DIR/cc_freeze.sh"

TMUX_CMD_STR="tmux -L $SOCKET -f /dev/null"
NOW="$(date +%s)"
DAY="$(date -r "$NOW" +%Y-%m-%d)"
SNOW="$(printf '\xe2\x9d\x84')"   # the tombstone sigil, out of the source line

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
  ccft*) ;;
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

# ── Fixtures ─────────────────────────────────────────────────────────────────
ln -s /bin/sh "$BIN/op"
ln -s /bin/sh "$BIN/claude"
# The leaf blocks on a FIFO, and nothing anywhere sleeps:
#   * `sleep` is not a shell, a wrapper, Claude or an MCP helper, so H4's last
#     row classifies it UNSAFE:sleep. A `sleep` leaf refuses the freeze exactly
#     as `sh -c` does, and as a child of `claude` it is `unsafe-tool-child`.
#   * open(2) on a FIFO with no writer blocks forever, in the process itself —
#     so the holder forks NO child and its pid never churns. A pid that was not
#     in the captured set is itself a stale-capture trigger (§3.1.7), which
#     would make the freeze flap and make "these pids died" true for the wrong
#     reason.
# The trailing `:` stops sh exec-ing the last command away, so the
# pane -> shell -> op -> claude tree keeps its depth and claude stays a
# GRANDCHILD.
mkfifo "$FIX/hold.fifo"
printf 'read _x < "%s/hold.fifo"\n' "$FIX" > "$FIX/hold.sh"
printf '"%s/claude" "%s/hold.sh"\n:\n' "$BIN" "$FIX" > "$FIX/oprun.sh"
CLAUDE_TREE_CMD="\"$BIN/op\" \"$FIX/oprun.sh\""

# base-index must be set BEFORE the session is created, or a -f /dev/null server
# numbers from 0 and every index assertion below is off by one.
_t new-session -d -s _seed -c /tmp
_t set-option -g base-index 1 >/dev/null
_t set-option -g pane-base-index 1 >/dev/null
_t set-option -g default-shell /bin/sh >/dev/null
# Every pane is a bare interactive shell (see THE FIXTURE RULE above). `sh -i`
# rather than a LOGIN shell so nothing of the user's is sourced: a login shell
# reads ~/.profile, and the continuity precmd hook would consume the very
# pending files this test reads back. ENV=/dev/null closes the -i path too.
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

# work:1..4 — window 2 is the target, 1/3/4 are the neighbours AC2 protects.
# No pane is given a command: each is the bare interactive shell the freeze
# classifier must accept, and the Claude trees are grown INSIDE two of them
# below, which is how the live shape arises (pane -> zsh -> op -> claude).
_t new-session -d -s work -n keep-1 -c /tmp
_t new-window  -t work:2 -n target -c /tmp
_t new-window  -t work:3 -n keep-3 -c /tmp
_t new-window  -t work:4 -n keep-4 -c /tmp
_t kill-session -t _seed
_t split-window -t work:2 -c /tmp
_t split-window -t work:2 -c /tmp

NS="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NS" != "1" ]; then echo "ABORT: expected 1 session on the test socket, found $NS"; exit 1; fi

_descendants() { # <root pid> -> descendants ONE PER LINE, root excluded
  ps -axo pid=,ppid= | awk -v r="$1" '
    { pid[NR]=$1; pp[$1]=$2; n=NR }
    END { q[1]=r; c=1; h=1
          while (h <= c) { cur=q[h]; h++
            for (i=1; i<=n; i++) if (pp[pid[i]] == cur) { c++; q[c]=pid[i] } }
          for (i=2; i<=c; i++) print q[i] }'
}
_pid_cmd() { ps -p "$1" -o command= 2>/dev/null; }
_count_lines() { grep -c . "$1" 2>/dev/null | tr -d ' '; }
_count_alive() { # <file of pids, ONE PER LINE>
  local n=0 p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if kill -0 "$p" 2>/dev/null; then n=$((n+1)); fi
  done < "$1"
  printf '%s' "$n"
}
_list_alive() { local p; while IFS= read -r p; do [ -z "$p" ] && continue
    kill -0 "$p" 2>/dev/null && printf '%s(%s) ' "$p" "$(_pid_cmd "$p" | cut -c1-40)"; done < "$1"; }

# ── Grow the fake Claude trees inside two bare shells ────────────────────────
# $TD is unique to this run, so a global count of `$BIN/claude` processes is
# exact. The send is retried, not just polled: keys typed before the pane's
# shell has drawn its first prompt are simply lost, and no amount of waiting
# recovers them.
_pane_id_at() { _t list-panes -t "work:$1" -F '#{pane_index} #{pane_id}' 2>/dev/null \
                  | awk -v i="$2" '$1==i { print $2; exit }'; }
# The needle is assembled INSIDE awk from two arguments, so the matcher's own
# argv never contains the string it is looking for. `ps | grep "$BIN/claude "`
# self-matches (ps sees the grep it is piped into) and reports one claude that
# does not exist — which silently satisfies the wait below.
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
TREE_PANE_1="$(_pane_id_at 2 1)"
TREE_PANE_2="$(_pane_id_at 2 2)"
if [ -z "$TREE_PANE_1" ] || [ -z "$TREE_PANE_2" ]; then
  echo "ABORT: could not resolve panes 1 and 2 of work:2"; exit 1
fi
_grow_claude_tree "$TREE_PANE_1" 1 || echo "  (warning: first claude tree did not come up)"
_grow_claude_tree "$TREE_PANE_2" 2 || echo "  (warning: second claude tree did not come up)"

# ── Premise ──────────────────────────────────────────────────────────────────
echo "[0] PREMISE: three panes, two live claude GRANDCHILDREN, all processes alive"
PANE_PIDS="$TD/pane_pids"
TREE="$TD/tree_before"
CLAUDE_PIDS="$TD/claude_pids"
for _try in 1 2 3 4 5 6 7 8 9 10; do
  _t list-panes -t work:2 -F '#{pane_pid}' > "$PANE_PIDS"
  : > "$TREE"; : > "$CLAUDE_PIDS"
  while IFS= read -r pp; do
    [ -z "$pp" ] && continue
    printf '%s\n' "$pp" >> "$TREE"
    _descendants "$pp" >> "$TREE"
  done < "$PANE_PIDS"
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$(_pid_cmd "$p")" in "$BIN/claude"*) printf '%s\n' "$p" >> "$CLAUDE_PIDS" ;; esac
  done < "$TREE"
  [ "$(_count_lines "$CLAUDE_PIDS")" = "2" ] && break
  sleep 0.4
done
sort -u "$TREE" -o "$TREE"

assert_eq "window 2 has 3 panes"       "$(_t list-panes -t work:2 | wc -l | tr -d ' ')" "3"
assert_eq "exactly 2 claude processes" "$(_count_lines "$CLAUDE_PIDS")" "2"
N_TREE="$(_count_lines "$TREE")"
N_ALIVE="$(_count_alive "$TREE")"
assert_eq "every captured pid is ALIVE before the freeze ($N_TREE pids)" "$N_ALIVE" "$N_TREE"
# claude must be a GRANDCHILD of pane_pid, not a direct child.
GRAND=0
while IFS= read -r cp; do
  [ -z "$cp" ] && continue
  cpp="$(ps -p "$cp" -o ppid= 2>/dev/null | tr -d ' ')"
  if ! grep -qx "$cpp" "$PANE_PIDS"; then GRAND=$((GRAND+1)); fi
done < "$CLAUDE_PIDS"
assert_eq "both claude processes are GRANDCHILDREN (behind the op wrapper)" "$GRAND" "2"

if [ "$fail" -ne 0 ]; then
  echo ""; echo "  Results: $pass passed, $fail failed (premise not established)"; exit 1
fi

SID_A="11111111-1111-4111-8111-111111111111"
SID_B="22222222-2222-4222-8222-222222222222"
i=0
while IFS= read -r p; do
  i=$((i+1))
  [ "$i" = "1" ] && echo "$SID_A" > "$PD/by-pid/$p.session-id"
  [ "$i" = "2" ] && echo "$SID_B" > "$PD/by-pid/$p.session-id"
done < "$CLAUDE_PIDS"

WINDOWS_BEFORE="$(_t list-windows -t work -F '#{window_index}:#{window_name}' | tr '\n' ' ')"
LAYOUT_BEFORE="$(_t display-message -p -t work:2 '#{window_layout}')"
PANE_IDS_BEFORE="$(_t list-panes -t work:2 -F '#{pane_index}=#{pane_id}' | tr '\n' ' ')"
PANE_PIDS_BEFORE="$(_t list-panes -t work:2 -F '#{pane_pid}' | tr '\n' ' ')"
echo "    windows before: $WINDOWS_BEFORE"
echo "    layout before:  $LAYOUT_BEFORE"
echo "    panes before:   $PANE_IDS_BEFORE"

# Pending/launch files that must not survive on a frozen pane (§3.1.12) — plus
# one on an UNRELATED window that must survive untouched.
_t list-panes -t work:2 -F '#{pane_id}' > "$TD/target_pane_ids"
i=0
while IFS= read -r pid; do
  i=$((i+1)); eval "TP$i=\"\$pid\""
  printf 'echo --resume %s\n' "$SID_A" > "$QD/${pid#%}"
  printf 'c --worktree stale\n'        > "$LD/${pid#%}"
done < "$TD/target_pane_ids"
OTHER_PANE="$(_t list-panes -t work:1 -F '#{pane_id}' | head -1)"
printf 'echo --resume other-sid\n' > "$QD/${OTHER_PANE#%}"
printf 'c --worktree other\n'      > "$LD/${OTHER_PANE#%}"

# ── Helpers over the API contract ────────────────────────────────────────────
_freeze() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_NO_SAVE=1 bash "$FREEZE" "$@"
}
# stdout is one row per PANE, plus container summary rows whose first field is
# the container level (WINDOW / SESSION). A consumer that counts pane outcomes
# must exclude the summaries — that is the whole reason they are distinguishable.
_pane_rows()    { printf '%s\n' "$1" | awk -F'\t' 'NF>=2 && $1!="WINDOW" && $1!="SESSION"'; }
_summary_rows() { printf '%s\n' "$1" | awk -F'\t' 'NF>=2 && ($1=="WINDOW" || $1=="SESSION")'; }
_row_for()      { printf '%s\n' "$1" | awk -F'\t' -v t="$2" 'NF>=2 && $2==t { print; exit }'; }
_col()          { printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NF>=2 { print $n; exit }'; }
_nrows()        { printf '%s\n' "$1" | grep -c . | tr -d ' '; }
_state_path()   { ls "$FD"/*/"$1.state" 2>/dev/null | head -1; }
_state_count()  { ls "$FD"/*/*.state 2>/dev/null | wc -l | tr -d ' '; }
_scalar()       { awk -F'\t' -v k="$2" '$1==k { print $2; exit }' "$1"; }
_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
_tagged() { # <file> <line type> <tag> -> one value per matching line
  awk -F'\t' -v lt="$2" -v tag="$3" '$1==lt {
    for (i=1; i<=NF; i++) if (index($i, tag) == 1) print substr($i, length(tag)+1) }' "$1"
}
_pane_opt() { _t show-options -p -t "$1" -v @cc-frozen 2>/dev/null || true; }
_title_of() { _t display-message -p -t "$1" '#{pane_title}' 2>/dev/null; }

# ── 1. AC1 — every pane becomes a tombstone, in place ────────────────────────
echo ""
echo "[1] AC1: freeze a 3-pane window with 2 Claude sessions"
OUT="$(_freeze freeze --no-save work:2 2>"$TD/err1")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
[ -s "$TD/err1" ] && printf '    stderr: %s\n' "$(head -3 "$TD/err1")"

PANE_ROWS="$(_pane_rows "$OUT")"
SUMMARY="$(_summary_rows "$OUT")"
assert_eq "exit code 0 when every pane freezes" "$RC" "0"
assert_eq "one stdout row per PANE (the atom), not one per window" "$(_nrows "$PANE_ROWS")" "3"
assert_eq "every pane row reports FROZE" \
  "$(printf '%s\n' "$PANE_ROWS" | awk -F'\t' '$1!="FROZE"' | grep -c . | tr -d ' ')" "0"
assert_eq "pane rows are targeted by session:index.pane" \
  "$(printf '%s\n' "$PANE_ROWS" | awk -F'\t' '{print $2}' | sort | tr '\n' ' ')" \
  "work:2.1 work:2.2 work:2.3 "
assert_eq "every pane row carries the 6-column freeze contract" \
  "$(printf '%s\n' "$PANE_ROWS" | awk -F'\t' 'NF!=6' | grep -c . | tr -d ' ')" "0"
assert_eq "each pane row counts ITSELF: 1 pane" \
  "$(printf '%s\n' "$PANE_ROWS" | awk -F'\t' '$4!=1' | grep -c . | tr -d ' ')" "0"
assert_eq "the sids reported across the pane rows total 2" \
  "$(printf '%s\n' "$PANE_ROWS" | awk -F'\t' '{s+=$5} END {print s+0}')" "2"
# A container summary is a different row type so a counter cannot treble-count.
assert_eq "exactly one container summary row for a window target" "$(_nrows "$SUMMARY")" "1"
assert_eq "the summary is the WINDOW level" "$(_col "$SUMMARY" 1)" "WINDOW"
assert_eq "the summary names the window, not a pane" "$(_col "$SUMMARY" 2)" "work:2"
assert_eq "the summary's last column is the window's pane count" \
  "$(printf '%s\n' "$SUMMARY" | awk -F'\t' '{print $NF; exit}')" "3"

KEY1="$(_col "$(_row_for "$OUT" work:2.1)" 3)"
KEY2="$(_col "$(_row_for "$OUT" work:2.2)" 3)"
KEY3="$(_col "$(_row_for "$OUT" work:2.3)" 3)"
assert_eq "every pane got its own key" \
  "$(printf '%s\n%s\n%s\n' "$KEY1" "$KEY2" "$KEY3" | sort -u | grep -c . | tr -d ' ')" "3"
for k in "$KEY1" "$KEY2" "$KEY3"; do assert_ne "a pane row carries a key" "$k" "-"; done

# --- the window is NOT restructured (the whole point of the pane atom)
assert_eq "the pane COUNT is unchanged" "$(_t list-panes -t work:2 | wc -l | tr -d ' ')" "3"
assert_eq "window_layout is byte-identical across the freeze" \
  "$(_t display-message -p -t work:2 '#{window_layout}')" "$LAYOUT_BEFORE"
assert_eq "every pane kept its pane id (respawned IN PLACE, not recreated)" \
  "$(_t list-panes -t work:2 -F '#{pane_index}=#{pane_id}' | tr '\n' ' ')" "$PANE_IDS_BEFORE"
# ...and the mechanism: a respawn means the pane's own pid changed.
assert_ne "the pane processes were respawned (pane_pid changed)" \
  "$(_t list-panes -t work:2 -F '#{pane_pid}' | tr '\n' ' ')" "$PANE_PIDS_BEFORE"
assert_eq "the window keeps its name" \
  "$(_t display-message -p -t work:2 '#{window_name}')" "target"

# --- every pane is a tombstone, and its claim is a PANE option
BADTITLE=0; BADCLAIM=0; BADRENAME=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  idx="${line%% *}"; pid="${line#* }"
  case "$idx" in 1) k="$KEY1"; s=1 ;; 2) k="$KEY2"; s=1 ;; *) k="$KEY3"; s=0 ;; esac
  want="$(printf '%s FROZEN %s 1p/%ss %s' "$SNOW" "$k" "$s" "$DAY")"
  got="$(_title_of "$pid")"
  [ "$got" = "$want" ] || { BADTITLE=$((BADTITLE+1)); echo "        pane $idx title: got [$got] want [$want]"; }
  [ "$(_pane_opt "$pid")" = "$k" ] || { BADCLAIM=$((BADCLAIM+1))
    echo "        pane $idx claim: got [$(_pane_opt "$pid")] want [$k]"; }
  [ "$(_t show-options -p -t "$pid" -v allow-rename 2>/dev/null)" = "off" ] || BADRENAME=$((BADRENAME+1))
done < <(_t list-panes -t work:2 -F '#{pane_index} #{pane_id}')
assert_eq "every pane carries the contract tombstone title" "$BADTITLE" "0"
assert_eq "every pane carries its own @cc-frozen claim (a PANE option)" "$BADCLAIM" "0"
assert_eq "allow-rename is off on every tombstone pane" "$BADRENAME" "0"

# --- the store: one entry per pane (§2.3 + delta "one state file per frozen pane")
assert_eq "one state file per frozen pane" "$(_state_count)" "3"
TOTAL_SIDS=0; TOTAL_PANELINES=0; BADUNIT=0; BADIDX=0; BADPANEID=0; BADGATE=0; BADTAB=0
RECPIDS="$TD/recorded_pids"; : > "$RECPIDS"
ALLSIDS="$TD/all_sids"; : > "$ALLSIDS"
for k in "$KEY1" "$KEY2" "$KEY3"; do
  SF="$(_state_path "$k")"
  if [ -z "$SF" ] || [ ! -s "$SF" ]; then no "state file exists for key $k" "no $FD/*/$k.state"; continue; fi
  ok "state file exists for key $k"
  echo "    --- $k ---"; sed 's/^/      /' "$SF"
  assert_eq "$k: line 1 is the version marker" "$(head -1 "$SF")" "$(printf 'v\t1')"
  assert_eq "$k: an integrity terminator is present" \
    "$(grep -c "$(printf 'end\t1')" "$SF" | tr -d ' ')" "1"
  [ "$(_scalar "$SF" unit)" = "pane" ] || BADUNIT=$((BADUNIT+1))
  [ "$(_scalar "$SF" window_index)" = "2" ] || BADIDX=$((BADIDX+1))
  # the entry must name the LIVE pane it claims, and that pane must claim it back
  spid="$(_scalar "$SF" pane_id)"
  [ "$(_pane_opt "$spid")" = "$k" ] || { BADPANEID=$((BADPANEID+1))
    echo "        $k: recorded pane_id [$spid] does not claim this key"; }
  [ "$(_scalar "$SF" sid_count)" = "$(_scalar "$SF" claude_procs)" ] || BADGATE=$((BADGATE+1))
  TOTAL_SIDS=$((TOTAL_SIDS + $(awk -F'\t' '$1=="sid"' "$SF" | wc -l | tr -d ' ')))
  TOTAL_PANELINES=$((TOTAL_PANELINES + $(awk -F'\t' '$1=="pane"' "$SF" | wc -l | tr -d ' ')))
  [ "$(grep -c "$(printf '\t\t')" "$SF" | tr -d ' ')" = "0" ] || BADTAB=$((BADTAB+1))
  { _tagged "$SF" pane ';PID='; _tagged "$SF" sid ';PID='; } >> "$RECPIDS"
  _tagged "$SF" sid ';CLAUDE_SID=' >> "$ALLSIDS"
done
echo "    ------------------"
assert_eq "every entry declares unit=pane"                 "$BADUNIT" "0"
assert_eq "every entry records window_index 2"             "$BADIDX" "0"
assert_eq "every entry names the live pane that claims it" "$BADPANEID" "0"
assert_eq "every entry's sid_count equals its claude_procs (the gate's own books)" "$BADGATE" "0"
assert_eq "no empty TAB-separated field in any state file" "$BADTAB" "0"
assert_eq "exactly one pane line per entry"                "$TOTAL_PANELINES" "3"
assert_eq "2 sid lines across the three entries"           "$TOTAL_SIDS" "2"
assert_eq "both session ids recorded, one per line" \
  "$(sort "$ALLSIDS" | grep . | tr '\n' ' ')" "$SID_A $SID_B "
assert_eq "every recorded sid is a 36-char uuid" \
  "$(grep -cv '^[0-9a-f-]\{36\}$' "$ALLSIDS" | tr -d ' ')" "0"
assert_eq "no ;DUP= marker ever reaches the store" \
  "$(cat "$FD"/*/*.state 2>/dev/null | grep -c 'DUP=' | tr -d ' ')" "0"
assert_eq "every recorded sid is ROLE=primary" \
  "$(cat "$FD"/*/*.state 2>/dev/null | awk -F'\t' '$1=="sid"' | grep -vc ';ROLE=primary' | tr -d ' ')" "0"
BADCWD=0
while IFS= read -r c; do
  [ -z "$c" ] && { BADCWD=$((BADCWD+1)); continue; }
  [ -d "$(_b64d "$c")" ] || BADCWD=$((BADCWD+1))
done < <(cat "$FD"/*/*.state 2>/dev/null | awk -F'\t' '$1=="pane" {
    for (i=1;i<=NF;i++) if (index($i,";CWD=")==1) print substr($i,6) }')
assert_eq "every pane entry records a decodable, existing cwd" "$BADCWD" "0"

# --- the processes: ALIVE before (asserted above) -> dead now, one pid per line
for _w in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(_count_alive "$TREE")" = "0" ] && break
  sleep 0.3
done
ALIVE_AFTER="$(_count_alive "$TREE")"
if [ "$ALIVE_AFTER" = "0" ]; then
  ok "all $N_TREE captured pids are dead after the freeze"
else
  no "all $N_TREE captured pids are dead after the freeze" "still alive: $(_list_alive "$TREE")"
fi
sort -u "$RECPIDS" -o "$RECPIDS"
NREC="$(_count_lines "$RECPIDS")"
if [ "${NREC:-0}" -ge 3 ]; then ok "the store records at least one pid per pane ($NREC)"
else no "the store records at least one pid per pane" "recorded $NREC pids"; fi
RALIVE="$(_count_alive "$RECPIDS")"
if [ "$RALIVE" = "0" ]; then ok "every ;PID= recorded in the store is dead"
else no "every ;PID= recorded in the store is dead" "still alive: $(_list_alive "$RECPIDS")"; fi
UNKNOWN=0
while IFS= read -r p; do grep -qx "$p" "$TREE" || UNKNOWN=$((UNKNOWN+1)); done < "$RECPIDS"
assert_eq "every recorded pid came from the pre-freeze tree" "$UNKNOWN" "0"

# --- side effects
MISSBANNER=0; MISSLOG=0
for k in "$KEY1" "$KEY2" "$KEY3"; do
  b="$(ls "$FD"/*/"$k.banner" 2>/dev/null | head -1)"
  [ -n "$b" ] && [ -s "$b" ] || MISSBANNER=$((MISSBANNER+1))
  grep -q "$k" "$FLOG" 2>/dev/null || MISSLOG=$((MISSLOG+1))
done
assert_eq "a banner is written for every frozen pane"          "$MISSBANNER" "0"
assert_eq "every freeze is recorded in the dedicated freeze log" "$MISSLOG" "0"

# A frozen pane must not be left holding a queued Claude resume, or the next
# nudge relaunches Claude into a tombstone and the next save attributes a dead
# typed command to it.
STALE_RESUME=0; STALE_LAUNCH=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  case "$(cat "$QD/${p#%}" 2>/dev/null)" in *--resume*) STALE_RESUME=$((STALE_RESUME+1)) ;; esac
  [ -e "$LD/${p#%}" ] && STALE_LAUNCH=$((STALE_LAUNCH+1))
done < "$TD/target_pane_ids"
assert_eq "no frozen pane is left with a queued Claude resume" "$STALE_RESUME" "0"
assert_eq "no frozen pane is left with a stale launch record"  "$STALE_LAUNCH" "0"
# and nothing outside the frozen window was touched
assert_eq "an unrelated window's pending file survives" \
  "$(cat "$QD/${OTHER_PANE#%}" 2>/dev/null)" "echo --resume other-sid"
assert_eq "an unrelated window's launch file survives" \
  "$(cat "$LD/${OTHER_PANE#%}" 2>/dev/null)" "c --worktree other"

# ── 2. AC2 — no window is renumbered, no window is restructured ──────────────
echo ""
echo "[2] AC2: freezing must not renumber any window, nor restructure one"
WINDOWS_AFTER="$(_t list-windows -t work -F '#{window_index}:#{window_name}' | tr '\n' ' ')"
printf '    windows after:  %s\n' "$WINDOWS_AFTER"
assert_eq "window index:name list is byte-identical" "$WINDOWS_AFTER" "$WINDOWS_BEFORE"
assert_eq "the session still has 4 windows" \
  "$(_t list-windows -t work | wc -l | tr -d ' ')" "4"
assert_eq "the neighbours still have one pane each" \
  "$(for w in 1 3 4; do _t list-panes -t "work:$w" | wc -l | tr -d ' '; done | tr '\n' ' ')" "1 1 1 "
assert_eq "the frozen window's pane count is stable" \
  "$(_t list-panes -t work:2 | wc -l | tr -d ' ')" "3"
assert_eq "the frozen window's layout is stable" \
  "$(_t display-message -p -t work:2 '#{window_layout}')" "$LAYOUT_BEFORE"

# ── 3. AC10 — idempotency ────────────────────────────────────────────────────
echo ""
echo "[3] AC10: freezing an already-frozen window succeeds and changes nothing"
SUMS_BEFORE="$(for k in "$KEY1" "$KEY2" "$KEY3"; do cksum < "$(_state_path "$k")" 2>/dev/null; done)"
TOMB_PIDS_BEFORE="$(_t list-panes -t work:2 -F '#{pane_pid}' | tr '\n' ' ')"
TITLES_BEFORE="$(_t list-panes -t work:2 -F '#{pane_title}' | tr '\n' '|')"
STATES_BEFORE="$(_state_count)"

OUT2="$(_freeze freeze --no-save work:2 2>"$TD/err2")"; RC2=$?
printf '    exit=%s stdout=[%s]\n' "$RC2" "$OUT2"
PANE_ROWS2="$(_pane_rows "$OUT2")"
assert_eq "second freeze exits 0" "$RC2" "0"
assert_eq "every pane reports ALREADY" \
  "$(printf '%s\n' "$PANE_ROWS2" | awk -F'\t' '$1!="ALREADY"' | grep -c . | tr -d ' ')" "0"
assert_eq "still one row per pane" "$(_nrows "$PANE_ROWS2")" "3"
assert_eq "the keys are the same keys" \
  "$(printf '%s\n' "$PANE_ROWS2" | awk -F'\t' '{print $3}' | sort | tr '\n' ' ')" \
  "$(printf '%s\n%s\n%s\n' "$KEY1" "$KEY2" "$KEY3" | sort | tr '\n' ' ')"
assert_eq "pane count still 3"           "$(_t list-panes -t work:2 | wc -l | tr -d ' ')" "3"
assert_eq "layout still byte-identical"  "$(_t display-message -p -t work:2 '#{window_layout}')" "$LAYOUT_BEFORE"
assert_eq "every state file is byte-identical" \
  "$(for k in "$KEY1" "$KEY2" "$KEY3"; do cksum < "$(_state_path "$k")" 2>/dev/null; done)" "$SUMS_BEFORE"
assert_eq "no extra state file was written" "$(_state_count)" "$STATES_BEFORE"
assert_eq "no tombstone pane was respawned again" \
  "$(_t list-panes -t work:2 -F '#{pane_pid}' | tr '\n' ' ')" "$TOMB_PIDS_BEFORE"
assert_eq "tombstone titles unchanged" \
  "$(_t list-panes -t work:2 -F '#{pane_title}' | tr '\n' '|')" "$TITLES_BEFORE"
assert_eq "window indices still unchanged" \
  "$(_t list-windows -t work -F '#{window_index}:#{window_name}' | tr '\n' ' ')" "$WINDOWS_BEFORE"

# ...and the same is true of a bare PANE target, the new atom (§3.1 <target> ::= %N)
OUT2b="$(_freeze freeze --no-save "$TP1" 2>/dev/null)"; RC2b=$?
printf '    pane-target exit=%s stdout=[%s]\n' "$RC2b" "$OUT2b"
assert_eq "freezing an already-frozen PANE by %%id exits 0" "$RC2b" "0"
assert_eq "it reports ALREADY"                              "$(_col "$OUT2b" 1)" "ALREADY"
assert_eq "it reports that pane's own key"                  "$(_col "$OUT2b" 3)" "$KEY1"
assert_eq "a bare pane target emits no container summary"   "$(_nrows "$(_summary_rows "$OUT2b")")" "0"

# A third call must be equally inert (idempotency is not a one-shot property).
OUT3="$(_freeze freeze --no-save work:2 2>/dev/null)"; RC3=$?
assert_eq "third freeze exits 0" "$RC3" "0"
assert_eq "third freeze still reports ALREADY for every pane" \
  "$(_pane_rows "$OUT3" | awk -F'\t' '$1!="ALREADY"' | grep -c . | tr -d ' ')" "0"
assert_eq "state files still byte-identical" \
  "$(for k in "$KEY1" "$KEY2" "$KEY3"; do cksum < "$(_state_path "$k")" 2>/dev/null; done)" "$SUMS_BEFORE"

# ── 4. Freezing an unresolvable target must not damage anything ──────────────
echo ""
echo "[4] Unresolvable target: exit 2, no state file, no window touched"
OUT4="$(_freeze freeze --no-save work:99 2>/dev/null)"; RC4=$?
printf '    exit=%s stdout=[%s]\n' "$RC4" "$OUT4"
assert_eq "exit code 2 for an unresolvable target" "$RC4" "2"
assert_eq "no extra state file was written" "$(_state_count)" "$STATES_BEFORE"
assert_eq "window list still unchanged" \
  "$(_t list-windows -t work -F '#{window_index}:#{window_name}' | tr '\n' ' ')" "$WINDOWS_BEFORE"
assert_eq "layout still unchanged" \
  "$(_t display-message -p -t work:2 '#{window_layout}')" "$LAYOUT_BEFORE"

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
