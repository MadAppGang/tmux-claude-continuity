#!/usr/bin/env bash
# freeze_restore_cycle.sh — AC4, AC5, AC6-AC9, AC11, AC13: the whole loop from a
# freeze, through a save and a server restart, to a sweep on the other side.
#
#   AC4   a frozen window comes back FROZEN as a tombstone, with ZERO Claude
#         resumes queued for it — that saving IS the feature.
#   AC5   an awake window comes back awake and resumes exactly as today.
#   AC11  a snapshot written by the OLD plugin restores clean, all windows awake.
#   AC13  the ledger survives the server restart: a window idle before the
#         restart is still idle after it, not reset to "just active".
#   AC6   an idle shell-only window is auto-frozen by the sweep.
#   AC7   a window running vim is SKIPPED, with the reason logged.
#   AC8   the attached session's active window is SKIPPED, with the reason logged.
#   AC9   --dry-run reports candidates and changes nothing.
#   FR3.6 with @claude-continuity-autofreeze off, the sweep freezes NOTHING,
#         whatever the idle ages. Checked before anything is switched on.
#
# The restart is real: the tmux server is killed and a new one is started on the
# same socket, then the windows are rebuilt the way tmux-resurrect rebuilds them
# (same names, same indices, same pane titles and cwds, panes parked on shells)
# and the real post_restore.sh is run against the enriched snapshot. That is the
# closest thing to a reboot that an isolated socket can produce; a genuine reboot
# is the only thing that certifies the hook registration itself.
#
# Time: the sweep's AND-rail needs both the ledger and #{window_activity} to be
# older than the threshold, so the clock is moved FORWARD with CC_NOW (a
# documented test escape) instead of waiting two days. AC13 does the opposite —
# it uses REAL elapsed seconds, because CC_NOW shifts the ledger and the live
# activity equally and so cannot tell them apart.
#
# Isolation: own tmux socket, `-f /dev/null` on EVERY tmux invocation, all state
# under /tmp, CC_TEST=1. The attached client of AC8 is a `script(1)` pty on the
# same private socket, and is killed in the EXIT trap.
#
# Usage: bash tests/freeze_restore_cycle.sh   (exit 0 = pass)

set -uo pipefail

SOCKET="ccrc$$"
TD="/tmp/ccrc-$$"
FD="$TD/frozen"
PD="$TD/panes"
LD="$TD/launch"
QD="$TD/pending"
RD="$TD/resurrect"
BIN="$TD/bin"
FIX="$TD/fix"
SHIM="$TD/shim"
LOG="$TD/cc.log"
FLOG="$TD/cc-freeze.log"
SNAP="$RD/last"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
FREEZE="$SCRIPT_DIR/cc_freeze.sh"
THAW="$SCRIPT_DIR/cc_thaw.sh"
POPUP="$SCRIPT_DIR/cc_popup.sh"
PRE_SAVE="$SCRIPT_DIR/pre_save.sh"
RESTORE="$SCRIPT_DIR/post_restore.sh"

TMUX_CMD_STR="tmux -L $SOCKET -f /dev/null"
NOW="$(date +%s)"
SWEEP_NOW=$((NOW + 4 * 86400))

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
  ccrc*) ;;
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
CLIENT_PID=""
_kill_fixtures() {
  ps -axo pid=,command= > "$TD/ps.exit" 2>/dev/null || return 0
  while read -r _p _rest; do
    [ -z "${_p:-}" ] && continue
    [ "$_p" = "$$" ] && continue
    # fixtures live under $TD; the AC8 client is a `script` pty holding this
    # private socket open. Both are ours, and neither can be a live-server process.
    case "$_rest" in
      *"$TD"*)          kill -9 "$_p" 2>/dev/null ;;
      *"-L $SOCKET"*)   kill -9 "$_p" 2>/dev/null ;;
    esac
  done < "$TD/ps.exit"
}
_teardown() {
  [ -n "$CLIENT_PID" ] && kill -9 "$CLIENT_PID" 2>/dev/null
  _t kill-server 2>/dev/null
  _kill_fixtures
  rm -rf "$TD"
}
trap _teardown EXIT INT TERM

mkdir -p "$FD" "$PD/by-pid" "$LD" "$QD" "$RD" "$BIN" "$FIX" "$SHIM"

MISSING=""
for s in "$FREEZE" "$POPUP" "$PRE_SAVE" "$RESTORE"; do
  [ -f "$s" ] || MISSING="$MISSING $s"
done
if [ -n "$MISSING" ]; then
  echo "  FAIL: required script(s) missing:$MISSING"
  echo ""; echo "  Results: 0 passed, 1 failed"; exit 1
fi

cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
exec $(command -v tmux) -L "$SOCKET" -f /dev/null "\$@"
EOF
chmod +x "$SHIM/tmux"

ln -s /bin/sh "$BIN/op"
ln -s /bin/sh "$BIN/claude"
ln -s /bin/sh "$BIN/vim"
# THE FIXTURE RULE, in the one file that needs BOTH halves of it:
#
#   * A pane that must FREEZE is a BARE INTERACTIVE SHELL — no `-c`, no operand,
#     no work — because §H4 classifies a shell carrying an operand as
#     SHELL-WITH-WORK => UNSAFE (the rail that catches a Claude mid-Bash-tool-
#     call). A pane parked on `sh -c '…'` is refused as `unsafe-process:sh`
#     before the subject of the test is ever reached. Trees are grown INSIDE the
#     bare shell with send-keys, which is how the live shape arises.
#   * A pane that must be REFUSED runs something genuinely unsafe — here `vim`,
#     and ONLY vim: grown inside a bare shell so the refusal reason is
#     attributable to `vim` and cannot be `unsafe-process:sh` wearing its name.
#   * Panes that post_restore must ARM have to look like restored shells: it
#     refuses to arm a pane already running a program, which is what protects a
#     live Claude on a manual restore. A bare interactive shell satisfies that
#     guard AND lives forever, so it serves both halves; `sh -c 'while :; do
#     sleep 5; done'` satisfies only the second and fails the first.
#
# Nothing sleeps anywhere. `sleep` is not a shell, a wrapper, Claude or an MCP
# helper, so H4's last row classifies it UNSAFE:sleep — under `vim` it would
# even let AC7 report the wrong basename. The holder blocks on open(2) of a
# writer-less FIFO instead: it never returns, forks no child, and churns no pid.
#
# One more thing the bare shell needs here, and only here: AC8 attaches a real
# client through `script(1)`, and `script` forwards EOF on its own stdin to that
# client as ^D. A bare interactive shell EXITS on ^D — so the active pane, and
# with it the whole window AC8 is about, is destroyed the moment the client
# arrives whenever this test's stdin is a pipe or a closed file (CI, `> log`,
# a test runner). tmux then makes the VIM window active, and AC7's window is
# skipped as "active-window-of-attached-session": AC8's reason wearing AC7's
# name, with both assertions failing far from their cause. `$ENV` is already
# pointed away from the user's files, so it costs nothing to point it at a file
# that sets `ignoreeof` — the shell stays bare, and no stray ^D can kill it.
mkfifo "$FIX/hold.fifo"
printf 'set -o ignoreeof\n' > "$FIX/shrc"
printf 'read _x < "%s/hold.fifo"\n' "$FIX" > "$FIX/hold.sh"
printf '"%s/claude" "%s/hold.sh"\n:\n' "$BIN" "$FIX" > "$FIX/oprun.sh"
CLAUDE_TREE_CMD="\"$BIN/op\" \"$FIX/oprun.sh\""
VIM_TREE_CMD="\"$BIN/vim\" \"$FIX/hold.sh\""

SID_AWAKE="aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
SID_FROZEN="bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
SID_LEGACY="cccccccc-3333-4333-8333-cccccccccccc"
CWD="$(cd /tmp && pwd -P)"

_opts() {
  _t set-option -g base-index 1 >/dev/null
  _t set-option -g pane-base-index 1 >/dev/null
  _t set-option -g default-shell /bin/sh >/dev/null
  _t set-option -g default-command "sh -i" >/dev/null
  _t set-environment -g ENV "$FIX/shrc" >/dev/null
  _t set-option -g @claude-continuity-panes-dir    "$PD" >/dev/null
  _t set-option -g @claude-continuity-launch-dir   "$LD" >/dev/null
  _t set-option -g @claude-continuity-pending-dir  "$QD" >/dev/null
  _t set-option -g @claude-continuity-log-file     "$LOG" >/dev/null
  _t set-option -g @claude-continuity-claude-cmd   "echo" >/dev/null
  _t set-option -g @claude-continuity-claudish-cmd "claudish" >/dev/null
  _t set-option -g @claude-continuity-freeze-dir   "$FD" >/dev/null
  _t set-option -g @resurrect-dir                  "$RD" >/dev/null
}

_pane_id_of() { _t list-panes -t "$1" -F '#{pane_index} #{pane_id}' 2>/dev/null \
    | awk -v i="$2" '$1==i { print $2; exit }'; }
# NEVER `-t ""`: tmux falls back to the CURRENT pane, so a title meant for one
# window lands on another and the assertion that reads it back "passes".
_settitle() { # <target window> <pane index> <title>
  local id; id="$(_pane_id_of "$1" "$2")"
  if [ -z "$id" ]; then no "pane $1.$2 exists to be titled" "list-panes returned nothing"; return 1; fi
  _t select-pane -t "$id" -T "$3"
}
_pane_count() { _t list-panes -t "$1" 2>/dev/null | wc -l | tr -d ' '; }
_frozen_opt() { _t show-options -w -t "$1" -v @cc-frozen 2>/dev/null || true; }
# The needle is assembled INSIDE awk from two arguments, so the matcher's own
# argv never contains the string it looks for: `ps | grep "$BIN/claude "`
# self-matches (ps sees the grep it is piped into) and reports a process that
# does not exist, which silently satisfies the wait. The send is RETRIED, not
# merely polled — keys typed before the pane's shell has drawn its first prompt
# are lost, and waiting does not bring them back.
_proc_count() { ps -axo pid=,command= \
    | awk -v b="$1" -v s="$2" 'index($0, b s) { n++ } END { print n+0 }'; }
_grow() { # <pane_id> <command> <needle dir> <needle leaf> <expected count>
  local _try
  [ -z "$1" ] && return 1
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ "$(_proc_count "$3" "$4")" -ge "$5" ] && return 0
    case "$_try" in 1|5|9) _t send-keys -t "$1" "$2" Enter ;; esac
    sleep 0.4
  done
  [ "$(_proc_count "$3" "$4")" -ge "$5" ]
}
_titles_of() { _t list-panes -t "$1" -F '#{pane_title}' 2>/dev/null | tr '\n' '|'; }
_state_path() { ls "$FD"/*/"$1.state" 2>/dev/null | head -1; }
_state_count() { ls "$FD"/*/*.state 2>/dev/null | wc -l | tr -d ' '; }
_scalar() { awk -F'\t' -v k="$2" '$1==k { print $2; exit }' "$1" 2>/dev/null; }
_field() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NF>=2 { print $n; exit }'; }
_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
_descendants() {
  ps -axo pid=,ppid= | awk -v r="$1" '
    { pid[NR]=$1; pp[$1]=$2; n=NR }
    END { q[1]=r; c=1; h=1
          while (h <= c) { cur=q[h]; h++
            for (i=1; i<=n; i++) if (pp[pid[i]] == cur) { c++; q[c]=pid[i] } }
          for (i=2; i<=c; i++) print q[i] }'
}
_pid_cmd() { ps -p "$1" -o command= 2>/dev/null; }
_find_desc() {
  local pp p
  while IFS= read -r pp; do
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      case "$(_pid_cmd "$p")" in *"$2"*) printf '%s' "$p"; return 0 ;; esac
    done < <(_descendants "$pp")
  done < <(_t list-panes -t "$1" -F '#{pane_pid}')
  return 1
}
_pending_files() { local f; for f in "$QD"/*; do [ -s "$f" ] && printf '%s\n' "$f"; done 2>/dev/null; }
_pending_for() { cat "$QD/${1#%}" 2>/dev/null; }

_freeze() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="${CC_NOW_OVERRIDE:-$NOW}" CC_NO_SAVE=1 CC_NO_NUDGE=1 bash "$FREEZE" "$@"
}
_list() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="${CC_NOW_OVERRIDE:-$NOW}" bash "$POPUP" --list 2>/dev/null
}
_list_row() { _list | awk -F'\t' -v s="$1" -v w="$2" '$2==s && $3==w { print; exit }'; }

# ═════════════════════════════════════════════════════════════════════════════
# PHASE A — the pre-restart server
# ═════════════════════════════════════════════════════════════════════════════
echo "[A] SETUP: five windows — awake claude, one to freeze, idle, vim, active"
_t new-session -d -s _seed -c /tmp
_opts
_t new-session -d -s work -n awake    -c /tmp
_t new-window  -t work:2 -n tofreeze  -c /tmp
_t split-window -t work:2 -c /tmp
_t new-window  -t work:3 -n idle-shell -c /tmp
_t new-window  -t work:4 -n has-vim   -c /tmp
_t new-window  -t work:5 -n active-win -c /tmp
_t kill-session -t _seed
# Grow the trees inside the bare shells (see THE FIXTURE RULE above). The target
# is always "one more than there is now", so the same call is correct before and
# after the restart without assuming how fast the old server's children died.
_grow_one() { # <pane_id> <command> <needle dir> <needle leaf> <what>
  _grow "$1" "$2" "$3" "$4" "$(( $(_proc_count "$3" "$4") + 1 ))" \
    || echo "  (warning: $5 did not come up)"
}
_grow_one "$(_pane_id_of work:1 1)" "$CLAUDE_TREE_CMD" "$BIN" "/claude " "the awake claude tree"
_grow_one "$(_pane_id_of work:2 1)" "$CLAUDE_TREE_CMD" "$BIN" "/claude " "the to-freeze claude tree"
_grow_one "$(_pane_id_of work:4 1)" "$VIM_TREE_CMD"    "$BIN" "/vim "    "the vim fixture"

NS="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NS" != "1" ]; then echo "ABORT: expected 1 session on the test socket, found $NS"; exit 1; fi
if [ "$(_t list-windows -t work | wc -l | tr -d ' ')" != "5" ]; then
  echo "ABORT: expected 5 windows"; exit 1
fi

_settitle work:1 1 "awake-pane"
_settitle work:3 1 "idle-pane"
_settitle work:4 1 "vim-pane"
_settitle work:5 1 "active-pane"

AWAKE_CLAUDE=""; FROZEN_CLAUDE=""; VIM_PID=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
  AWAKE_CLAUDE="$(_find_desc work:1 "$BIN/claude" || true)"
  FROZEN_CLAUDE="$(_find_desc work:2 "$BIN/claude" || true)"
  VIM_PID="$(_find_desc work:4 "$BIN/vim" || true)"
  [ -n "$AWAKE_CLAUDE" ] && [ -n "$FROZEN_CLAUDE" ] && [ -n "$VIM_PID" ] && break
  sleep 0.4
done
if [ -n "$AWAKE_CLAUDE" ]; then ok "the awake window has a live claude ($AWAKE_CLAUDE)"
else no "the awake window has a live claude"; fi
if [ -n "$FROZEN_CLAUDE" ]; then ok "the window to freeze has a live claude ($FROZEN_CLAUDE)"
else no "the window to freeze has a live claude"; fi
if [ -n "$VIM_PID" ]; then ok "the vim window has a live vim ($VIM_PID: $(_pid_cmd "$VIM_PID" | cut -c1-40))"
else no "the vim window has a live vim"; fi
if [ "$fail" -ne 0 ]; then
  echo ""; echo "  Results: $pass passed, $fail failed (premise not established)"; exit 1
fi
echo "$SID_AWAKE"  > "$PD/by-pid/$AWAKE_CLAUDE.session-id"
echo "$SID_FROZEN" > "$PD/by-pid/$FROZEN_CLAUDE.session-id"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE B — freeze window 2
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[B] FREEZE work:2"
OUT="$(_freeze freeze --no-save work:2 2>/dev/null)"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "verb is FROZE" "$(_field "$OUT" 1)" "FROZE"
KEY="$(_field "$OUT" 3)"
SF="$(_state_path "$KEY")"
if [ -z "$SF" ] || [ ! -s "$SF" ]; then
  no "state file written" "nothing to carry through the restart"
  echo ""; echo "  Results: $pass passed, $fail failed"; exit 1
fi
ok "state file written ($SF)"
TOMB_ID="$(_pane_id_of work:2 1)"
[ -n "$TOMB_ID" ] || TOMB_ID="__nopane__"
TOMB_TITLE="$(_t display-message -p -t "$TOMB_ID" '#{pane_title}' 2>/dev/null || true)"
OLD_SERVER_PID="$(_scalar "$SF" server_pid)"
OLD_WINDOW_ID="$(_scalar "$SF" window_id)"
printf '    tombstone title: [%s]\n    recorded server_pid=%s window_id=%s\n' \
  "$TOMB_TITLE" "$OLD_SERVER_PID" "$OLD_WINDOW_ID"
assert_has "the tombstone title carries the frozen marker and the key" "$TOMB_TITLE" "FROZEN $KEY"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE C — the save: build a resurrect-shaped snapshot and enrich it
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[C] SAVE: pre_save.sh enriches the snapshot; the frozen window carries no sid"
_row() { # <window index> <pane index> <title> <cmd> <full_command>
  printf 'pane\twork\t%s\t1\t:*\t%s\t%s\t:%s\t1\t%s\t:%s\n' \
    "$1" "$2" "$3" "$CWD" "$4" "$5"
}
{
  _row 1 1 "awake-pane"    claude "claude --dangerously-skip-permissions"
  _row 2 1 "$TOMB_TITLE"   sh     "sh"
  _row 3 1 "idle-pane"     sh     "sh"
  _row 4 1 "vim-pane"      sh     "sh"
  _row 5 1 "active-pane"   sh     "sh"
} > "$SNAP"
LINES_BEFORE="$(grep -c . "$SNAP" | tr -d ' ')"
CC_TEST=1 PATH="$SHIM:$PATH" TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  bash "$PRE_SAVE" "$SNAP" >/dev/null 2>&1
echo "    --- enriched snapshot ---"; sed 's/^/      /' "$SNAP"; echo "    -------------------------"

ROW_AWAKE="$(awk -F'\t' '$1=="pane" && $3==1' "$SNAP")"
ROW_FROZEN="$(awk -F'\t' '$1=="pane" && $3==2' "$SNAP")"
assert_eq  "the snapshot still has one line per pane and no new line types" \
  "$(grep -c . "$SNAP" | tr -d ' ')" "$LINES_BEFORE"
assert_eq  "every line is still a pane line" \
  "$(awk -F'\t' '$1!="pane"' "$SNAP" | grep -c . | tr -d ' ')" "0"
assert_has "the awake window's row carries its session id" "$ROW_AWAKE" ";CLAUDE_SID=$SID_AWAKE"
assert_has "the frozen window's row carries the ❄ marker in the pane title" \
  "$ROW_FROZEN" "$(printf '\xe2\x9d\x84 FROZEN %s' "$KEY")"
assert_hasnt "the frozen window's row carries NO session id" "$ROW_FROZEN" ";CLAUDE_SID="

# AC13's clock starts here: the ledger has just been ticked by this save.
LEDGER_T0="$(date +%s)"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE D — the restart, and post_restore
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[D] RESTART: kill the server, rebuild the windows, run post_restore.sh"
# Real elapsed time, so AC13 can tell a ledger-derived idle age from one derived
# from #{window_activity} (which the restart resets to now).
sleep 8
_t kill-server 2>/dev/null
sleep 0.5
if _t list-sessions >/dev/null 2>&1; then no "the old server is gone"; else ok "the old server is gone"; fi

_t new-session -d -s _seed -c /tmp
_opts
# Bare interactive shells: post_restore refuses to arm a pane already running a
# program, so a restored pane must BE a restored shell — and a bare shell lives
# forever without holding any work, which is the same shape the freeze rail
# requires (see THE FIXTURE RULE above).
_t new-session -d -s work -n awake    -c /tmp
_t new-window  -t work:2 -n tofreeze  -c /tmp
_t new-window  -t work:3 -n idle-shell -c /tmp
_t new-window  -t work:4 -n has-vim   -c /tmp
_t new-window  -t work:5 -n active-win -c /tmp
_t kill-session -t _seed
_grow_one "$(_pane_id_of work:4 1)" "$VIM_TREE_CMD" "$BIN" "/vim " "the restored vim fixture"
_settitle work:1 1 "awake-pane"
_settitle work:2 1 "$TOMB_TITLE"
_settitle work:3 1 "idle-pane"
_settitle work:4 1 "vim-pane"
_settitle work:5 1 "active-pane"

NEW_SERVER_PID="$(_t display-message -p '#{pid}')"
NEW_WINDOW_ID="$(_t display-message -p -t work:2 '#{window_id}')"
AWAKE_PANE="$(_pane_id_of work:1 1)"
TOMB_PANE="$(_pane_id_of work:2 1)"
printf '    new server pid=%s  work:2 window_id=%s\n' "$NEW_SERVER_PID" "$NEW_WINDOW_ID"
assert_ne "the server really restarted (new pid)" "$NEW_SERVER_PID" "$OLD_SERVER_PID"

rm -f "$QD"/*
: > "$LOG"
CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" RESURRECT_FILE="$SNAP" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  bash "$RESTORE" >/dev/null 2>&1
RESTORE_RC=$?
RESTORE_LOG="$(cat "$LOG" 2>/dev/null)"
echo "    --- post_restore log ---"; sed 's/^/      /' "$LOG" 2>/dev/null | head -30
echo "    ------------------------"
assert_eq "post_restore exits 0 on every path" "$RESTORE_RC" "0"

# ── AC4 ──────────────────────────────────────────────────────────────────────
echo ""
echo "[D1] AC4: the frozen window comes back FROZEN, with zero resumes queued"
assert_has "the tombstone row was re-claimed, by key" "$RESTORE_LOG" "FROZEN-CLAIMED"
assert_has "the claim names this window and key" "$RESTORE_LOG" "key=$KEY"
assert_eq  "the window carries the @cc-frozen claim again" "$(_frozen_opt work:2)" "$KEY"
assert_eq  "allow-rename is off on the tombstone pane" \
  "$(_t show-options -p -t "$TOMB_PANE" -v allow-rename 2>/dev/null || true)" "off"
assert_has "the tombstone pane still shows the ❄ title" "$(_titles_of work:2)" "FROZEN $KEY"
assert_eq  "the frozen window still has exactly one pane" "$(_pane_count work:2)" "1"
# The whole point of the feature: nothing is resumed for a frozen window.
assert_hasnt "no Claude resume was queued for the tombstone pane" \
  "$(_pending_for "$TOMB_PANE")" "--resume"
assert_hasnt "the frozen window's session id was not resumed anywhere" \
  "$(cat $(_pending_files) 2>/dev/null)" "$SID_FROZEN"
# The state file must be re-pointed at the LIVE server and window, or the next
# thaw would act on a window id that no longer means anything.
SF_AFTER="$(_state_path "$KEY")"
if [ -n "$SF_AFTER" ] && [ -s "$SF_AFTER" ]; then
  ok "the state file survived the restart"
  assert_eq "server_pid was rewritten to the live server" "$(_scalar "$SF_AFTER" server_pid)" "$NEW_SERVER_PID"
  assert_eq "window_id was rewritten to the live window"   "$(_scalar "$SF_AFTER" window_id)" "$NEW_WINDOW_ID"
  assert_eq "the recorded sid is still there for a later thaw" \
    "$(awk -F'\t' '$1=="sid" { for (i=1;i<=NF;i++) if (index($i,";CLAUDE_SID=")==1) print substr($i,13) }' "$SF_AFTER")" \
    "$SID_FROZEN"
else
  no "the state file survived the restart" "no $FD/*/$KEY.state"
fi

# ── AC5 ──────────────────────────────────────────────────────────────────────
echo ""
echo "[D2] AC5: the awake window resumes exactly as it does today"
assert_has "a resume was routed for the awake pane" "$RESTORE_LOG" "resume=$SID_AWAKE"
assert_has "it was routed to the awake pane itself" "$RESTORE_LOG" "-> $AWAKE_PANE"
assert_has "its pending file carries the session id" "$(_pending_for "$AWAKE_PANE")" "--resume $SID_AWAKE"
assert_hasnt "the awake pane did not get the frozen window's session" \
  "$(_pending_for "$AWAKE_PANE")" "$SID_FROZEN"

# ── the inventory surface ────────────────────────────────────────────────────
echo ""
echo "[D3] The inventory reports the two windows in different states"
echo "    --- cc_popup.sh --list ---"; _list | sed 's/^/      /'; echo "    --------------------------"
assert_eq "work:2 is FROZEN"  "$(_field "$(_list_row work 2)" 1)" "FROZEN"
assert_eq "work:1 is AWAKE"   "$(_field "$(_list_row work 1)" 1)" "AWAKE"
assert_eq "the frozen row carries the key" "$(_field "$(_list_row work 2)" 9)" "$KEY"
assert_has "the boot verdict mentions the frozen inventory" "$RESTORE_LOG" "frozen window(s) held in the store"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE E — AC11: an OLD-format snapshot
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[E] AC11: a snapshot written by the OLD plugin restores clean, all awake"
# Bare interactive shells: these are the panes post_restore must ARM from the
# old-format snapshot, and it arms only panes that are restored shells.
_t new-session -d -s legacy -n legacy-a -c /tmp
_t new-window  -t legacy:2 -n legacy-b -c /tmp
LEG_A="$(_pane_id_of legacy:1 1)"; LEG_B="$(_pane_id_of legacy:2 1)"
_settitle legacy:1 1 "legacy-pane-a"
_settitle legacy:2 1 "legacy-pane-b"
OLDSNAP="$TD/old-format-snapshot"
# Exactly the three sentinel columns the old plugin emitted, no ❄ anywhere.
{
  printf 'pane\tlegacy\t1\t1\t:*\t1\tlegacy-pane-a\t:%s\t1\tclaude\t:claude --dangerously-skip-permissions\t;CLAUDE_SID=%s\n' \
    "$CWD" "$SID_LEGACY"
  printf 'pane\tlegacy\t2\t0\t:-\t1\tlegacy-pane-b\t:%s\t1\tnode\t:node /Users/jack/.bun/bin/claudish -d\t;CLAUDE_SID=%s\t;CLAUDISH_REPLAY=-d --model g@gemini-3-pro\n' \
    "$CWD" "sid-legacy-claudish"
} > "$OLDSNAP"
rm -f "$QD"/*
: > "$LOG"
CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" RESURRECT_FILE="$OLDSNAP" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  bash "$RESTORE" >/dev/null 2>&1
OLD_RC=$?
OLD_LOG="$(cat "$LOG" 2>/dev/null)"
assert_eq  "post_restore exits 0"                    "$OLD_RC" "0"
assert_has "the legacy claude row resumed"           "$(_pending_for "$LEG_A")" "--resume $SID_LEGACY"
assert_has "the legacy claudish row resumed via claudish" "$(_pending_for "$LEG_B")" "claudish"
assert_has "the legacy claudish replay flags survived"    "$(_pending_for "$LEG_B")" "--model g@gemini-3-pro"
assert_hasnt "no frozen handling fired for an old snapshot" "$OLD_LOG" "FROZEN-"
assert_eq  "legacy:1 is AWAKE" "$(_field "$(_list_row legacy 1)" 1)" "AWAKE"
assert_eq  "legacy:2 is AWAKE" "$(_field "$(_list_row legacy 2)" 1)" "AWAKE"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE F — AC13: the ledger survives the restart
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[F] AC13: idle age is read from the LEDGER, so a restart does not reset it"
ELAPSED=$(( $(date +%s) - LEDGER_T0 ))
IDLE_ROW="$(_list_row work 3)"
IDLE_SECS="$(_field "$IDLE_ROW" 5)"
printf '    %s seconds of real time have passed since the ledger was ticked\n' "$ELAPSED"
printf '    reported idle for work:3 = [%s]\n' "$IDLE_SECS"
case "$IDLE_SECS" in
  ''|*[!0-9]*) no "idle age is a number" "got [$IDLE_SECS]" ;;
  *) ok "idle age is a number"
     if [ "$IDLE_SECS" -ge 6 ]; then
       ok "idle age survived the server restart (>= 6s, not reset to ~0)"
     else
       no "idle age survived the server restart" \
          "reported ${IDLE_SECS}s after ${ELAPSED}s — #{window_activity} was reset by the restart, so this is the live value, not the ledger's"
     fi ;;
esac

# ═════════════════════════════════════════════════════════════════════════════
# PHASE G — the sweep
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[G1] FR3.6: with autofreeze off, the sweep freezes NOTHING at any idle age"
_t set-option -g @claude-continuity-autofreeze-idle "2d" >/dev/null
_t set-option -g @claude-continuity-autofreeze "off" >/dev/null
STATES_BEFORE="$(_state_count)"
PANES_BEFORE="$(_t list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' | tr '\n' ' ')"
OUT="$(CC_NOW=$SWEEP_NOW CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" \
       CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" CC_NO_SAVE=1 CC_NO_NUDGE=1 \
       bash "$FREEZE" sweep 2>/dev/null)"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$(printf '%s' "$OUT" | tr '\n' '/')"
assert_eq "exit code 0"                    "$RC" "0"
assert_eq "not one FROZE line"             "$(printf '%s\n' "$OUT" | grep -c '^FROZE')" "0"
assert_eq "no state file was created"      "$(_state_count)" "$STATES_BEFORE"
assert_eq "no pane was destroyed"          "$(_t list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' | tr '\n' ' ')" "$PANES_BEFORE"

echo ""
echo "[G2] AC8 setup: attach a real client and make work:5 its active window"
_t select-window -t work:5
( script -q /dev/null tmux -L "$SOCKET" -f /dev/null attach -t work >/dev/null 2>&1 ) &
CLIENT_PID=$!
CLIENTS=0
for _try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  CLIENTS="$(_t list-clients -F '#{client_tty}' 2>/dev/null | grep -c .)"
  [ "$CLIENTS" -ge 1 ] && break
  sleep 0.3
done
assert_eq "a client is attached to session work" "$CLIENTS" "1"
# Select AFTER the client is attached, and confirm it took. Selecting before the
# attach is not durable: the arriving client re-establishes the session's
# current window, and the whole of AC7/AC8 then tests the WRONG window — the
# vim window gets skipped as "active", which is AC8's reason wearing AC7's name.
for _try in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(_t display-message -p -t work '#{window_index}')" = "5" ] && break
  _t select-window -t work:5 2>/dev/null
  sleep 0.3
done
assert_eq "work:5 is the attached session's active window" \
  "$(_t display-message -p -t work '#{window_index}')" "5"

echo ""
echo "[G3] AC9: --dry-run reports candidates and changes nothing"
_t set-option -g @claude-continuity-autofreeze "on" >/dev/null
STATES_BEFORE="$(_state_count)"
PANES_BEFORE="$(_t list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' | tr '\n' ' ')"
TITLES_BEFORE="$(_t list-panes -a -F '#{pane_title}' | tr '\n' '|')"
DRY="$(CC_NOW=$SWEEP_NOW CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" \
       CC_LOG_FILE="$LOG" CC_NO_SAVE=1 CC_NO_NUDGE=1 bash "$FREEZE" sweep --dry-run 2>/dev/null)"; RC=$?
echo "    --- sweep --dry-run ---"; printf '%s\n' "$DRY" | sed 's/^/      /'; echo "    -----------------------"
assert_eq "exit code 0"                     "$RC" "0"
assert_eq "not one FROZE line"              "$(printf '%s\n' "$DRY" | grep -c '^FROZE')" "0"
assert_eq "no state file was created"       "$(_state_count)" "$STATES_BEFORE"
assert_eq "no pane was destroyed"           "$(_t list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' | tr '\n' ' ')" "$PANES_BEFORE"
assert_eq "no pane title was rewritten"     "$(_t list-panes -a -F '#{pane_title}' | tr '\n' '|')" "$TITLES_BEFORE"
assert_eq "the idle shell window is reported as a candidate" \
  "$(printf '%s\n' "$DRY" | awk -F'\t' '$1=="WOULD-FREEZE" && $2=="work:3"' | grep -c .)" "1"
assert_eq "every line is one of the three contracted verbs" \
  "$(printf '%s\n' "$DRY" | grep -c . )" \
  "$(printf '%s\n' "$DRY" | grep -cE '^(WOULD-FREEZE|SKIP|FROZE)[[:space:]]')"

echo ""
echo "[G4] AC7 + AC8: the safety rails skip, with reasons, in the dry run"
SKIP_VIM="$(printf '%s\n' "$DRY" | awk -F'\t' '$1=="SKIP" && $2=="work:4" { print $4 }')"
SKIP_ACT="$(printf '%s\n' "$DRY" | awk -F'\t' '$1=="SKIP" && $2=="work:5" { print $4 }')"
SKIP_FRZ="$(printf '%s\n' "$DRY" | awk -F'\t' '$1=="SKIP" && $2=="work:2" { print $4 }')"
printf '    work:4=[%s] work:5=[%s] work:2=[%s]\n' "$SKIP_VIM" "$SKIP_ACT" "$SKIP_FRZ"
assert_eq  "AC7: the vim window is skipped as unsafe, naming vim" "$SKIP_VIM" "unsafe-process:vim"
assert_eq  "AC8: the attached session's active window is skipped" "$SKIP_ACT" "active-window-of-attached-session"
assert_eq  "an already-frozen window is skipped as such"          "$SKIP_FRZ" "already-frozen"
assert_hasnt "the vim window is not a freeze candidate"  "$(printf '%s\n' "$DRY" | grep 'work:4')" "WOULD-FREEZE"
assert_hasnt "the active window is not a freeze candidate" "$(printf '%s\n' "$DRY" | grep 'work:5')" "WOULD-FREEZE"

echo ""
echo "[G5] AC6: the real sweep freezes the idle shell-only window"
STATES_BEFORE="$(_state_count)"
RUN="$(CC_NOW=$SWEEP_NOW CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" \
       CC_LOG_FILE="$LOG" CC_NO_SAVE=1 CC_NO_NUDGE=1 bash "$FREEZE" sweep 2>/dev/null)"; RC=$?
echo "    --- sweep ---"; printf '%s\n' "$RUN" | sed 's/^/      /'; echo "    -------------"
assert_eq "exit code 0" "$RC" "0"
FROZE_LINE="$(printf '%s\n' "$RUN" | awk -F'\t' '$1=="FROZE" && $2=="work:3"')"
if [ -n "$FROZE_LINE" ]; then ok "AC6: work:3 was auto-frozen"
else no "AC6: work:3 was auto-frozen" "no FROZE line for work:3"; fi
assert_eq "work:3 collapsed to a tombstone pane" "$(_pane_count work:3)" "1"
assert_has "work:3's pane carries a ❄ title" "$(_titles_of work:3)" "$(printf '\xe2\x9d\x84 FROZEN')"
assert_eq "work:3 now reports FROZEN in the inventory" "$(_field "$(_list_row work 3)" 1)" "FROZEN"
assert_ne "a new state file was written" "$(_state_count)" "$STATES_BEFORE"

# The rails held through the real run, not just the dry run.
assert_eq "AC7: vim window still untouched"    "$(_pane_count work:4)" "1"
assert_hasnt "AC7: vim window has no ❄ title"  "$(_titles_of work:4)" "$(printf '\xe2\x9d\x84 FROZEN')"
assert_hasnt "AC8: active window has no ❄ title" "$(_titles_of work:5)" "$(printf '\xe2\x9d\x84 FROZEN')"
assert_eq "AC8: the active window is still awake" "$(_field "$(_list_row work 5)" 1)" "AWAKE"
# Every skip must be printed AND logged with its reason (§3.3.3, FR3.4, AC7,
# AC8). The contract says "logged"; it does not say which file, so both the
# dedicated freeze log and the main log are read — the assertion is that the
# reason was recorded somewhere durable, not that a particular file holds it.
FREEZE_LOG="$(cat "$FLOG" "$LOG" 2>/dev/null)"
assert_has "AC7: the vim skip is logged with its reason"    "$FREEZE_LOG" "unsafe-process:vim"
assert_has "AC8: the active-window skip is logged"          "$FREEZE_LOG" "active-window-of-attached-session"

# stdout is a contract: nothing may be frozen that the sweep did not announce.
ANNOUNCED="$(printf '%s\n' "$RUN" | awk -F'\t' '$1=="FROZE" && $2 ~ /^work:/ { print $2 }' | sort | tr '\n' ' ')"
FROZEN_NOW="$(_list | awk -F'\t' '$1=="FROZEN" && $2=="work" && $3!=2 { print $2":"$3 }' | sort | tr '\n' ' ')"
assert_eq "exactly the announced windows became frozen" "$FROZEN_NOW" "$ANNOUNCED"

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
