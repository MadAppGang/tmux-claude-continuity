#!/usr/bin/env bash
# freeze_tombstone.sh — AC1, AC2, AC10 for `cc_freeze.sh freeze`.
#
#   AC1  3-pane window, 2 running Claude  -> freeze -> 1 pane remains; a state
#        file lists 3 panes + 2 session ids; the 3 original pane PIDs are gone.
#   AC2  frozen window at index 2 of 4    -> the other 3 indices are unchanged.
#   AC10 freeze twice                     -> the second call succeeds (ALREADY,
#        exit 0) and changes nothing.
#
# Asserted against the API contract in architecture §3.1 and the on-disk state
# file format in §2.3 — never against any implementation detail.
#
# Two design rules this file obeys, both learned from false passes in this repo:
#   * "the processes are gone" is only meaningful after asserting they were
#     ALIVE. Every pid is iterated ONE PER LINE (`kill -0 "1 2 3"` always fails,
#     which reports every process dead and passes forever).
#   * the MECHANISM is asserted, not just the end state: the tombstone title,
#     the recorded ;PID= tags, the state file's own counters and the stdout TSV
#     must all agree with each other and with the live server.
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
#   is caught by its own parent and the window refuses to freeze. Parking a
#   fixture on `sh -c` therefore makes EVERY freeze return
#   `REFUSED … unsafe-process:sh` and proves nothing about the tombstone.
#   It matches production, too: every real pane process on this machine is a
#   bare `/bin/zsh` or `-zsh`, for Claude panes and idle panes alike.
#   The unsafe path is exercised deliberately, where it is the point, in
#   tests/freeze_gates.sh — not smuggled in through the scaffolding here.
#
# Isolation: own tmux socket, `-f /dev/null` on EVERY tmux invocation, every
# directory under /tmp, CC_TEST=1 so the implementation re-checks the contract.
#
# Usage: bash tests/freeze_tombstone.sh   (exit 0 = pass)

set -uo pipefail

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
trap _teardown EXIT INT TERM

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
_list_alive_ids() { local p; while IFS= read -r p; do [ -z "$p" ] && continue
    kill -0 "$p" 2>/dev/null && printf '%s ' "$p"; done < "$1"; }
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
echo "    windows before: $WINDOWS_BEFORE"

# Pending/launch files that must be cleaned up for the destroyed panes (§3.1.12)
# — plus one on an UNRELATED window that must survive untouched.
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
_field() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NF>=2 { print $n; exit }'; }
_state_path() { ls "$FD"/*/"$1.state" 2>/dev/null | head -1; }
_state_count() { ls "$FD"/*/*.state 2>/dev/null | wc -l | tr -d ' '; }
_scalar() { awk -F'\t' -v k="$2" '$1==k { print $2; exit }' "$1"; }
_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
_tagged() { # <file> <line type> <tag> -> one value per matching line
  awk -F'\t' -v lt="$2" -v tag="$3" '$1==lt {
    for (i=1; i<=NF; i++) if (index($i, tag) == 1) print substr($i, length(tag)+1) }' "$1"
}

# ── 1. AC1 — freeze collapses to a tombstone and records everything ──────────
echo ""
echo "[1] AC1: freeze a 3-pane window with 2 Claude sessions"
OUT="$(_freeze freeze --no-save work:2 2>"$TD/err1")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
[ -s "$TD/err1" ] && printf '    stderr: %s\n' "$(head -3 "$TD/err1")"

assert_eq "exit code 0 on success"           "$RC" "0"
assert_eq "exactly one TSV line for one target" "$(printf '%s\n' "$OUT" | grep -c .)" "1"
VERB="$(_field "$OUT" 1)"
assert_eq "stdout verb is FROZE"             "$VERB" "FROZE"
assert_eq "stdout target is work:2"          "$(_field "$OUT" 2)" "work:2"
assert_eq "stdout pane count is 3"           "$(_field "$OUT" 4)" "3"
assert_eq "stdout sid count is 2"            "$(_field "$OUT" 5)" "2"
KEY="$(_field "$OUT" 3)"
assert_ne "stdout carries a key"             "$KEY" "-"

# --- the window itself
assert_eq "window collapsed to exactly 1 pane" "$(_t list-panes -t work:2 | wc -l | tr -d ' ')" "1"
TOMB_ID="$(_t list-panes -t work:2 -F '#{pane_id}' | head -1)"
# NEVER pass an empty -t: tmux silently falls back to the CURRENT pane, which
# turns "the tombstone looks right" into a comparison of one unrelated pane with
# itself. A bogus id makes every read below fail loudly instead.
if [ -z "$TOMB_ID" ]; then
  no "the frozen window still has a pane to read" "work:2 lists no panes"
  TOMB_ID="__nopane__"
fi
TOMB_TITLE="$(_t display-message -p -t "$TOMB_ID" '#{pane_title}' 2>/dev/null)"
printf '    tombstone title: [%s]\n' "$TOMB_TITLE"
assert_eq "tombstone title is the contract string" \
  "$TOMB_TITLE" "$(printf '\xe2\x9d\x84 FROZEN %s 3p/2s %s' "$KEY" "$DAY")"
assert_eq "allow-rename is off on the tombstone pane" \
  "$(_t show-options -p -t "$TOMB_ID" -v allow-rename 2>/dev/null || true)" "off"
assert_eq "the window carries the @cc-frozen claim" \
  "$(_t show-options -w -t work:2 -v @cc-frozen 2>/dev/null)" "$KEY"
assert_eq "the window keeps its name" \
  "$(_t display-message -p -t work:2 '#{window_name}')" "target"

# --- the state file (§2.3)
SF="$(_state_path "$KEY")"
if [ -n "$SF" ] && [ -s "$SF" ]; then ok "state file exists for the key ($SF)"
else no "state file exists for the key" "no $FD/*/$KEY.state"; fi
if [ -n "$SF" ] && [ -s "$SF" ]; then
  echo "    --- state file ---"; sed 's/^/      /' "$SF"; echo "    ------------------"
  assert_eq "line 1 is the version marker" "$(head -1 "$SF")" "$(printf 'v\t1')"
  assert_eq "last line is the integrity terminator" "$(tail -1 "$SF")" "$(printf 'end\t1')"
  assert_eq "pane_count is 3"    "$(_scalar "$SF" pane_count)" "3"
  assert_eq "sid_count is 2"     "$(_scalar "$SF" sid_count)"  "2"
  assert_eq "claude_procs is 2 (the gate's denominator)" "$(_scalar "$SF" claude_procs)" "2"
  assert_eq "window_index is 2"  "$(_scalar "$SF" window_index)" "2"
  assert_eq "3 pane lines"       "$(awk -F'\t' '$1=="pane"' "$SF" | wc -l | tr -d ' ')" "3"
  assert_eq "2 sid lines"        "$(awk -F'\t' '$1=="sid"'  "$SF" | wc -l | tr -d ' ')" "2"
  assert_eq "pane indices are 1 2 3" \
    "$(awk -F'\t' '$1=="pane" {print $2}' "$SF" | sort -n | tr '\n' ' ')" "1 2 3 "
  assert_eq "session name decodes to work" "$(_b64d "$(_scalar "$SF" session)")" "work"
  assert_eq "window name decodes to target" "$(_b64d "$(_scalar "$SF" window_name)")" "target"
  assert_ne "layout string recorded" "$(_scalar "$SF" layout)" ""
  # one session per line, and both ids are the ones we planted
  assert_eq "both session ids recorded, one per line" \
    "$(_tagged "$SF" sid ';CLAUDE_SID=' | sort | tr '\n' ' ')" "$SID_A $SID_B "
  # One session per line: a line count, a tag count and an occurrence count must
  # all agree, or a two-Claude pane is unrepresentable and `grep -c` lies.
  assert_eq "CLAUDE_SID occurrence count agrees with sid_count" \
    "$(grep -o 'CLAUDE_SID=' "$SF" | wc -l | tr -d ' ')" "2"
  assert_eq "every recorded sid is a 36-char uuid" \
    "$(_tagged "$SF" sid ';CLAUDE_SID=' | grep -cv '^[0-9a-f-]\{36\}$' | tr -d ' ')" "0"
  assert_eq "no ;DUP= marker ever reaches the state file" \
    "$(grep -c 'DUP=' "$SF" | tr -d ' ')" "0"
  assert_eq "both sids are ROLE=primary" \
    "$(_tagged "$SF" sid ';ROLE=' | grep -c '^primary$' | tr -d ' ')" "2"
  # every pane line carries a non-empty cwd that decodes to a real directory
  BADCWD=0
  while IFS= read -r c; do
    [ -z "$c" ] && { BADCWD=$((BADCWD+1)); continue; }
    [ -d "$(_b64d "$c")" ] || BADCWD=$((BADCWD+1))
  done < <(_tagged "$SF" pane ';CWD=')
  assert_eq "every pane records a decodable, existing cwd" "$BADCWD" "0"
  # No empty TAB field anywhere in the file (FR6.2 applies to the store too).
  assert_eq "no empty TAB-separated field in the state file" \
    "$(grep -c "$(printf '\t\t')" "$SF" | tr -d ' ')" "0"
fi

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
if [ -n "$SF" ] && [ -s "$SF" ]; then
  RECPIDS="$TD/recorded_pids"
  { _tagged "$SF" pane ';PID='; _tagged "$SF" sid ';PID='; } | sort -u | grep . > "$RECPIDS"
  NREC="$(_count_lines "$RECPIDS")"
  if [ "${NREC:-0}" -ge 3 ]; then ok "state file records at least one pid per pane ($NREC)"
  else no "state file records at least one pid per pane" "recorded $NREC pids"; fi
  RALIVE="$(_count_alive "$RECPIDS")"
  if [ "$RALIVE" = "0" ]; then ok "every ;PID= recorded in the state file is dead"
  else no "every ;PID= recorded in the state file is dead" "still alive: $(_list_alive "$RECPIDS")"; fi
  # and the recorded pids really were part of the pre-freeze tree
  UNKNOWN=0
  while IFS= read -r p; do grep -qx "$p" "$TREE" || UNKNOWN=$((UNKNOWN+1)); done < "$RECPIDS"
  assert_eq "every recorded pid came from the pre-freeze tree" "$UNKNOWN" "0"
fi

# --- side effects
BANNER="$(ls "$FD"/*/"$KEY.banner" 2>/dev/null | head -1)"
if [ -n "$BANNER" ] && [ -s "$BANNER" ]; then ok "banner file written ($BANNER)"
else no "banner file written" "no non-empty $FD/*/$KEY.banner"; fi
if grep -q "$KEY" "$FLOG" 2>/dev/null; then ok "the freeze is recorded in the dedicated freeze log"
else no "the freeze is recorded in the dedicated freeze log" "no mention of $KEY in $FLOG"; fi

# The destroyed panes' pending + launch files must go, or the next nudge relaunches
# Claude into a tombstone and the next save attributes a dead typed command to it.
for v in TP2 TP3; do
  eval "p=\${$v:-}"
  [ -z "$p" ] && continue
  if [ -e "$QD/${p#%}" ]; then no "pending file removed for destroyed pane $p" \
      "still present: $(cat "$QD/${p#%}")"; else ok "pending file removed for destroyed pane $p"; fi
  if [ -e "$LD/${p#%}" ]; then no "launch file removed for destroyed pane $p" \
      "still present: $(cat "$LD/${p#%}")"; else ok "launch file removed for destroyed pane $p"; fi
done
# Pane 1 is respawned as the tombstone rather than destroyed; whatever is queued
# for it, it must never be a Claude resume.
STALE_RESUME=0
while IFS= read -r p; do
  [ -z "$p" ] && continue
  case "$(cat "$QD/${p#%}" 2>/dev/null)" in *--resume*) STALE_RESUME=$((STALE_RESUME+1)) ;; esac
done < "$TD/target_pane_ids"
assert_eq "no frozen pane is left with a queued Claude resume" "$STALE_RESUME" "0"
# and nothing outside the frozen window was touched
assert_eq "an unrelated window's pending file survives" \
  "$(cat "$QD/${OTHER_PANE#%}" 2>/dev/null)" "echo --resume other-sid"
assert_eq "an unrelated window's launch file survives" \
  "$(cat "$LD/${OTHER_PANE#%}" 2>/dev/null)" "c --worktree other"

# ── 2. AC2 — no window is renumbered ─────────────────────────────────────────
echo ""
echo "[2] AC2: freezing must not renumber any window"
WINDOWS_AFTER="$(_t list-windows -t work -F '#{window_index}:#{window_name}' | tr '\n' ' ')"
printf '    windows after:  %s\n' "$WINDOWS_AFTER"
assert_eq "window index:name list is byte-identical" "$WINDOWS_AFTER" "$WINDOWS_BEFORE"
assert_eq "the session still has 4 windows" \
  "$(_t list-windows -t work | wc -l | tr -d ' ')" "4"
assert_eq "the neighbours still have one pane each" \
  "$(for w in 1 3 4; do _t list-panes -t "work:$w" | wc -l | tr -d ' '; done | tr '\n' ' ')" "1 1 1 "

# ── 3. AC10 — idempotency ────────────────────────────────────────────────────
echo ""
echo "[3] AC10: freezing an already-frozen window succeeds and changes nothing"
if [ -z "$SF" ] || [ ! -s "$SF" ]; then
  no "AC10 state-file invariance" "the first freeze produced no state file to compare"
  SF="$TD/.nostate"; : > "$SF"
fi
SUM_BEFORE="$(cksum < "$SF" 2>/dev/null)"
TOMB_PID_BEFORE="$(_t list-panes -t work:2 -F '#{pane_pid}' | head -1)"
[ -n "$TOMB_PID_BEFORE" ] || TOMB_PID_BEFORE="__nopane__"
STATES_BEFORE="$(_state_count)"

OUT2="$(_freeze freeze --no-save work:2 2>"$TD/err2")"; RC2=$?
printf '    exit=%s stdout=[%s]\n' "$RC2" "$OUT2"
assert_eq "second freeze exits 0"        "$RC2" "0"
assert_eq "second freeze reports ALREADY" "$(_field "$OUT2" 1)" "ALREADY"
assert_eq "second freeze reports the same key" "$(_field "$OUT2" 3)" "$KEY"
assert_eq "still exactly 1 pane"         "$(_t list-panes -t work:2 | wc -l | tr -d ' ')" "1"
assert_eq "state file is byte-identical" "$(cksum < "$SF" 2>/dev/null)" "$SUM_BEFORE"
assert_eq "no second state file was written" "$(_state_count)" "$STATES_BEFORE"
TOMB_PID_AFTER="$(_t list-panes -t work:2 -F '#{pane_pid}' | head -1)"
[ -n "$TOMB_PID_AFTER" ] || TOMB_PID_AFTER="__nopane__"
assert_eq "the tombstone pane was not respawned" "$TOMB_PID_AFTER" "$TOMB_PID_BEFORE"
assert_eq "tombstone title unchanged" \
  "$(_t display-message -p -t "$TOMB_ID" '#{pane_title}' 2>/dev/null || true)" "$TOMB_TITLE"
assert_eq "window indices still unchanged" \
  "$(_t list-windows -t work -F '#{window_index}:#{window_name}' | tr '\n' ' ')" "$WINDOWS_BEFORE"
assert_eq "@cc-frozen claim unchanged" \
  "$(_t show-options -w -t work:2 -v @cc-frozen 2>/dev/null)" "$KEY"

# A third call must be equally inert (idempotency is not a one-shot property).
OUT3="$(_freeze freeze --no-save work:2 2>/dev/null)"; RC3=$?
assert_eq "third freeze exits 0"          "$RC3" "0"
assert_eq "third freeze reports ALREADY"  "$(_field "$OUT3" 1)" "ALREADY"
assert_eq "state file still byte-identical" "$(cksum < "$SF" 2>/dev/null)" "$SUM_BEFORE"

# ── 4. Freezing an unresolvable target must not damage anything ──────────────
echo ""
echo "[4] Unresolvable target: exit 2, no state file, no window touched"
OUT4="$(_freeze freeze --no-save work:99 2>/dev/null)"; RC4=$?
printf '    exit=%s stdout=[%s]\n' "$RC4" "$OUT4"
assert_eq "exit code 2 for an unresolvable target" "$RC4" "2"
assert_eq "no extra state file was written" "$(_state_count)" "$STATES_BEFORE"
assert_eq "window list still unchanged" \
  "$(_t list-windows -t work -F '#{window_index}:#{window_name}' | tr '\n' ' ')" "$WINDOWS_BEFORE"

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
