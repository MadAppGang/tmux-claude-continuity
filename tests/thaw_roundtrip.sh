#!/usr/bin/env bash
# thaw_roundtrip.sh — AC3, AC12, AC15 for `cc_thaw.sh thaw` (§3.2).
#
#   AC3   a frozen window thaws back to its recorded panes, cwds, titles and
#         layout, with one pending-resume queued per recorded session id.
#   AC15  a frozen CLAUDISH pane relaunches through `claudish` with its recorded
#         replay flags — never through a plain `claude --resume`.
#   AC12  a thaw that fails midway leaves the window frozen and the state file
#         intact: no data loss, and the window is still thawable afterwards.
#
# A NOTE ON ONE CONTRACT CONFLICT, resolved in favour of the API contract:
#   AC3 (requirements) says "state file removed" on a successful thaw.
#   §3.2.9 (architecture) says the opposite and says why: the file stays in
#   place with a `thawed_at<TAB><epoch>` line appended, and pre_save.sh archives
#   it only once every ROLE=primary sid is observed live in a snapshot — so a
#   reboot in the thaw->save gap leaves a recoverable entry instead of bare
#   shells and nothing. This test asserts §3.2.9 (the later, reasoned document)
#   and asserts AC3's USER-VISIBLE half separately: the window is no longer a
#   tombstone and no longer claims a frozen key. If the implementation deletes
#   the file instead, that is a contract conflict to resolve, not a test bug.
#
# Fixtures are fake: symlinks to /bin/sh carrying the argv[0] the classifier
# keys on. The claude pane is a GRANDCHILD behind an `op` wrapper; the claudish
# pane is `node …/claudish --model … -d` behind an interpreter prefix.
#
# THE FIXTURE RULE: a pane that must FREEZE is a BARE INTERACTIVE SHELL, and the
# fake Claude/claudish trees are grown inside it with send-keys. §H4 classifies
# a shell carrying an operand (`sh -c '<work>'`) as SHELL-WITH-WORK => UNSAFE —
# the rail that catches a Claude mid-Bash-tool-call — so a pane parked on
# `sh -c` is refused before this test's subject is ever reached. Nothing sleeps
# either: `sleep` is UNSAFE by H4's last row. The leaves block on a writer-less
# FIFO, which never returns, forks no child, and churns no pid.
#
# Isolation: own tmux socket, `-f /dev/null` on EVERY tmux invocation, all state
# under /tmp, CC_TEST=1, CC_NO_NUDGE=1 so nothing is typed into a pane and the
# pending files stay on disk to be read back.
#
# Usage: bash tests/thaw_roundtrip.sh   (exit 0 = pass)

set -uo pipefail

SOCKET="ccth$$"
TD="/tmp/ccth-$$"
FD="$TD/frozen"
PD="$TD/panes"
LD="$TD/launch"
QD="$TD/pending"
RD="$TD/resurrect"
BIN="$TD/bin"
FIX="$TD/fix"
LOG="$TD/cc.log"
FLOG="$TD/cc-freeze.log"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
FREEZE="$SCRIPT_DIR/cc_freeze.sh"
THAW="$SCRIPT_DIR/cc_thaw.sh"

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
assert_hasnt() { case "$2" in *"$3"*) no "$1" "must NOT contain [$3]; got [$(_trunc "$2")]" ;; *) ok "$1" ;; esac; }

# ── PRE-FLIGHT GUARD ─────────────────────────────────────────────────────────
case "$SOCKET" in
  default|""|*/*|*\ *) echo "ABORT: unsafe socket name [$SOCKET]"; exit 1 ;;
  ccth*) ;;
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

mkdir -p "$FD" "$PD/by-pid" "$LD" "$QD" "$RD" "$BIN" "$FIX" \
         "$TD/cwd-claude" "$TD/cwd-claudish" "$TD/cwd-shell"

MISSING=""
[ -f "$FREEZE" ] || MISSING="$MISSING $FREEZE"
[ -f "$THAW" ]   || MISSING="$MISSING $THAW"
if [ -n "$MISSING" ]; then
  echo "  FAIL: required script(s) missing:$MISSING"
  echo ""; echo "  Results: 0 passed, 1 failed"; exit 1
fi

# macOS reports symlink-resolved cwds (/tmp -> /private/tmp); assertions must use
# the resolved form or every cwd comparison fails for the wrong reason.
CWD_CLAUDE="$(cd "$TD/cwd-claude" && pwd -P)"
CWD_CLAUDISH="$(cd "$TD/cwd-claudish" && pwd -P)"
CWD_SHELL="$(cd "$TD/cwd-shell" && pwd -P)"

ln -s /bin/sh "$BIN/op"
ln -s /bin/sh "$BIN/claude"
ln -s /bin/sh "$BIN/node"
# A leaf blocked on open(2) of a writer-less FIFO, not a sleep: `sleep` is not a
# shell, a wrapper, Claude or an MCP helper, so H4's last row classifies it
# UNSAFE:sleep and it would refuse the freeze this test depends on; as a child
# of claude it would be `unsafe-tool-child:sleep`. The FIFO blocks forever in
# the holder itself, so no child is forked and no pid ever churns — and a pid
# that was not in the captured set is a stale-capture trigger (§3.1.7), while a
# pid that dies of old age makes "these pids died" true for the wrong reason.
# The trailing `:` keeps sh from exec-ing the last command away, preserving the
# tree's depth so claude stays a GRANDCHILD.
mkfifo "$FIX/hold.fifo"
printf 'read _x < "%s/hold.fifo"\n' "$FIX" > "$FIX/loop.sh"
printf 'read _x < "%s/hold.fifo"\n' "$FIX" > "$FIX/claudish"
printf '"%s/claude" "%s/loop.sh"\n:\n' "$BIN" "$FIX" > "$FIX/oprun.sh"

REPLAY_FLAGS="--model cx@gpt-5.6-sol -d"
CLAUDE_TREE_CMD="\"$BIN/op\" \"$FIX/oprun.sh\""
CLAUDISH_TREE_CMD="\"$BIN/node\" \"$FIX/claudish\" $REPLAY_FLAGS"

_t new-session -d -s _seed -c /tmp
_t set-option -g base-index 1 >/dev/null
_t set-option -g pane-base-index 1 >/dev/null
_t set-option -g default-shell /bin/sh >/dev/null
# Panes the IMPLEMENTATION creates must not source anything of the user's: a
# login shell would read ~/.profile, and the continuity precmd hook would eat
# the very pending files this test reads back.
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

# Every pane is created bare (the freezable shape); the trees are grown inside
# them once the helpers below exist.
_t new-session -d -s work -n roundtrip -c "$CWD_CLAUDE"
_t split-window -t work:1 -c "$CWD_CLAUDISH"
_t split-window -t work:1 -c "$CWD_SHELL"
_t new-window  -t work:2 -n failhalf -c "$CWD_CLAUDE"
_t split-window -t work:2 -c "$CWD_SHELL"
_t kill-session -t _seed

NS="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NS" != "1" ]; then echo "ABORT: expected 1 session on the test socket, found $NS"; exit 1; fi

_pane_id_of() { # <window> <pane index> -> pane id, or empty (NEVER an empty -t)
  _t list-panes -t "work:$1" -F '#{pane_index} #{pane_id}' 2>/dev/null \
    | awk -v i="$2" '$1==i { print $2; exit }'
}
i=0
while IFS= read -r pid; do
  i=$((i+1))
  _t select-pane -t "$pid" -T "roundtrip-pane-$i"
done < <(_t list-panes -t work:1 -F '#{pane_id}')

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
_tree_of_window() {
  : > "$2"; local pp
  while IFS= read -r pp; do
    [ -z "$pp" ] && continue
    printf '%s\n' "$pp" >> "$2"; _descendants "$pp" >> "$2"
  done < <(_t list-panes -t "$1" -F '#{pane_pid}')
  sort -u "$2" -o "$2"
}
_find_desc() { # <window> <substring> -> first matching descendant pid
  local pp p
  while IFS= read -r pp; do
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      case "$(_pid_cmd "$p")" in *"$2"*) printf '%s' "$p"; return 0 ;; esac
    done < <(_descendants "$pp")
  done < <(_t list-panes -t "$1" -F '#{pane_pid}')
  return 1
}
_pane_count() { _t list-panes -t "$1" 2>/dev/null | wc -l | tr -d ' '; }
_frozen_opt() { _t show-options -w -t "$1" -v @cc-frozen 2>/dev/null || true; }
_state_path() { ls "$FD"/*/"$1.state" 2>/dev/null | head -1; }
_scalar() { awk -F'\t' -v k="$2" '$1==k { print $2; exit }' "$1" 2>/dev/null; }
_field() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NF>=2 { print $n; exit }'; }
_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
_tagval() { printf '%s\n' "$1" | awk -F'\t' -v t="$2" '
  { for (i=1; i<=NF; i++) if (index($i, t) == 1) { print substr($i, length(t)+1); exit } }'; }
_pending_files() { # non-empty pending files ONLY: a zero-byte file is not a queued resume
  local f; for f in "$QD"/*; do [ -s "$f" ] && printf '%s\n' "$f"; done 2>/dev/null
}
_pending_count() { _pending_files | grep -c . | tr -d ' '; }
_titles_of() { _t list-panes -t "$1" -F '#{pane_title}' 2>/dev/null | tr '\n' '|'; }

# ── Grow the fake Claude / claudish trees inside the bare shells ─────────────
# The needle is assembled INSIDE awk from two arguments so the matcher's own
# argv never contains it: `ps | grep "$BIN/claude "` self-matches (ps sees the
# grep it is piped into) and reports a process that does not exist. The send is
# retried, not merely polled — keys typed before the pane's shell has drawn its
# first prompt are lost, and no amount of waiting brings them back.
_proc_count() { ps -axo pid=,command= \
    | awk -v b="$1" -v s="$2" 'index($0, b s) { n++ } END { print n+0 }'; }
_grow() { # <pane_id> <command> <needle dir> <needle leaf> <expected count>
  local _try
  for _try in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ "$(_proc_count "$3" "$4")" -ge "$5" ] && return 0
    case "$_try" in 1|5|9) _t send-keys -t "$1" "$2" Enter ;; esac
    sleep 0.4
  done
  [ "$(_proc_count "$3" "$4")" -ge "$5" ]
}
GROW_CLAUDE="$(_pane_id_of 1 1)"
GROW_CLAUDISH="$(_pane_id_of 1 2)"
GROW_CLAUDE2="$(_pane_id_of 2 1)"
if [ -z "$GROW_CLAUDE" ] || [ -z "$GROW_CLAUDISH" ] || [ -z "$GROW_CLAUDE2" ]; then
  echo "ABORT: could not resolve the panes the fixtures must be grown in"; exit 1
fi
_grow "$GROW_CLAUDE"   "$CLAUDE_TREE_CMD"   "$BIN" "/claude "   1 \
  || echo "  (warning: window 1's claude tree did not come up)"
_grow "$GROW_CLAUDISH" "$CLAUDISH_TREE_CMD" "$FIX" "/claudish " 1 \
  || echo "  (warning: the claudish tree did not come up)"
_grow "$GROW_CLAUDE2"  "$CLAUDE_TREE_CMD"   "$BIN" "/claude "   2 \
  || echo "  (warning: window 2's claude tree did not come up)"

_freeze() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_NO_SAVE=1 CC_NO_NUDGE=1 bash "$FREEZE" "$@"
}
_thaw() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_NO_SAVE=1 CC_NO_NUDGE=1 bash "$THAW" "$@"
}

# ── Premise ──────────────────────────────────────────────────────────────────
echo "[0] PREMISE: a 3-pane window with one claude GRANDCHILD and one claudish"
CLAUDE_PID=""; CLAUDISH_PID=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
  CLAUDE_PID="$(_find_desc work:1 "$BIN/claude" || true)"
  CLAUDISH_PID="$(_find_desc work:1 "$FIX/claudish" || true)"
  [ -n "$CLAUDE_PID" ] && [ -n "$CLAUDISH_PID" ] && break
  sleep 0.4
done
assert_eq "window 1 has 3 panes" "$(_pane_count work:1)" "3"
if [ -n "$CLAUDE_PID" ]; then ok "claude process is live ($CLAUDE_PID)"
else no "claude process is live" "no descendant matching $BIN/claude"; fi
if [ -n "$CLAUDISH_PID" ]; then ok "claudish process is live ($CLAUDISH_PID)"
else no "claudish process is live" "no descendant matching $FIX/claudish"; fi
if [ -n "$CLAUDE_PID" ]; then
  PPID_OF="$(ps -p "$CLAUDE_PID" -o ppid= 2>/dev/null | tr -d ' ')"
  PANE1_PID="$(_t list-panes -t work:1 -F '#{pane_pid}' | head -1)"
  assert_ne "claude is a GRANDCHILD, not a direct child of the pane" "$PPID_OF" "$PANE1_PID"
fi
_tree_of_window work:1 "$TD/tree1"
assert_eq "every pid in the window is ALIVE before the freeze" \
  "$(_count_alive "$TD/tree1")" "$(_count_lines "$TD/tree1")"
if [ "$fail" -ne 0 ]; then
  echo ""; echo "  Results: $pass passed, $fail failed (premise not established)"; exit 1
fi

SID_CLAUDE="aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
SID_CLAUDISH="bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
SID_FAILHALF="cccccccc-3333-4333-8333-cccccccccccc"
echo "$SID_CLAUDE"   > "$PD/by-pid/$CLAUDE_PID.session-id"
echo "$SID_CLAUDISH" > "$PD/by-pid/$CLAUDISH_PID.session-id"

# ── 1. Freeze, and record what the thaw is contracted to restore ─────────────
echo ""
echo "[1] FREEZE: the capture the thaw will be judged against"
OUT="$(_freeze freeze --no-save work:1 2>"$TD/e1")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "freeze succeeded"     "$RC" "0"
assert_eq "verb is FROZE"        "$(_field "$OUT" 1)" "FROZE"
assert_eq "3 panes captured"     "$(_field "$OUT" 4)" "3"
assert_eq "2 sids captured"      "$(_field "$OUT" 5)" "2"
KEY="$(_field "$OUT" 3)"
SF="$(_state_path "$KEY")"
if [ -z "$SF" ] || [ ! -s "$SF" ]; then
  no "state file exists" "no $FD/*/$KEY.state — nothing to thaw"
  echo ""; echo "  Results: $pass passed, $fail failed"; exit 1
fi
ok "state file exists ($SF)"
echo "    --- state file ---"; sed 's/^/      /' "$SF"; echo "    ------------------"
assert_eq "window collapsed to 1 pane" "$(_pane_count work:1)" "1"

REC_LAYOUT="$(_scalar "$SF" layout)"
REC_PANES="$TD/rec_panes"; awk -F'\t' '$1=="pane"' "$SF" > "$REC_PANES"
REC_SIDS="$TD/rec_sids";   awk -F'\t' '$1=="sid"'  "$SF" > "$REC_SIDS"
assert_eq "3 pane lines recorded" "$(_count_lines "$REC_PANES")" "3"
assert_eq "2 sid lines recorded"  "$(_count_lines "$REC_SIDS")"  "2"

# AC15's precondition: the claudish pane's replay flags are in the store.
CLAUDISH_SID_LINE="$(grep 'CLASS=claudish' "$REC_SIDS" | head -1)"
if [ -n "$CLAUDISH_SID_LINE" ]; then
  ok "the claudish session is recorded with CLASS=claudish"
  REC_REPLAY="$(_b64d "$(_tagval "$CLAUDISH_SID_LINE" ';REPLAY=')")"
  printf '    recorded replay: [%s]\n' "$REC_REPLAY"
  assert_has "recorded replay carries the model flag" "$REC_REPLAY" "--model cx@gpt-5.6-sol"
  assert_has "recorded replay carries -d"             "$REC_REPLAY" "-d"
  assert_eq  "the claudish sid is the one we planted" \
    "$(_tagval "$CLAUDISH_SID_LINE" ';CLAUDE_SID=')" "$SID_CLAUDISH"
else
  no "the claudish session is recorded with CLASS=claudish" \
     "no sid line carries ;CLASS=claudish: $(cat "$REC_SIDS")"
  REC_REPLAY=""
fi

# ── 2. AC3 — thaw rebuilds the window ────────────────────────────────────────
echo ""
echo "[2] AC3: thaw rebuilds panes, cwds, titles and layout, and queues the resumes"
rm -f "$QD"/*
OUT="$(_thaw thaw --no-save work:1 2>"$TD/e2")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
[ -s "$TD/e2" ] && printf '    stderr: %s\n' "$(head -3 "$TD/e2")"
assert_eq "exit code 0"            "$RC" "0"
assert_eq "verb is THAWED"         "$(_field "$OUT" 1)" "THAWED"
assert_eq "stdout target is work:1" "$(_field "$OUT" 2)" "work:1"
assert_eq "stdout key matches"     "$(_field "$OUT" 3)" "$KEY"
assert_eq "stdout pane count is 3" "$(_field "$OUT" 4)" "3"
assert_eq "stdout queued count is 2" "$(_field "$OUT" 5)" "2"

assert_eq "the window has 3 panes again" "$(_pane_count work:1)" "3"

# cwds and titles, pane by pane, against the recorded capture
BADCWD=0; BADTITLE=0; MISSINGPANE=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  idx="$(printf '%s\n' "$line" | awk -F'\t' '{print $2}')"
  pid="$(_pane_id_of 1 "$idx")"
  if [ -z "$pid" ]; then MISSINGPANE=$((MISSINGPANE+1)); continue; fi
  want_cwd="$(_b64d "$(_tagval "$line" ';CWD=')")"
  want_title="$(_b64d "$(_tagval "$line" ';TITLE=')")"
  got_cwd="$(_t display-message -p -t "$pid" '#{pane_current_path}' 2>/dev/null)"
  got_title="$(_t display-message -p -t "$pid" '#{pane_title}' 2>/dev/null)"
  [ "$got_cwd" = "$want_cwd" ] || { BADCWD=$((BADCWD+1))
    echo "        pane $idx cwd: got [$got_cwd] want [$want_cwd]"; }
  [ "$got_title" = "$want_title" ] || { BADTITLE=$((BADTITLE+1))
    echo "        pane $idx title: got [$got_title] want [$want_title]"; }
done < "$REC_PANES"
assert_eq "every recorded pane index exists again" "$MISSINGPANE" "0"
assert_eq "every pane came back in its recorded cwd" "$BADCWD" "0"
assert_eq "every pane came back with its recorded title" "$BADTITLE" "0"

# A tmux layout string is `<checksum>,<cell>[,<cell>…]`, where a LEAF cell is
# `WxH,X,Y,<pane_id>` and a container cell is `WxH,X,Y` followed by `[`/`{`.
# Two fields in it are not contract guarantees and must not be asserted on:
#   * the leading checksum, which tmux recomputes; and
#   * the per-leaf PANE ID, which is server-assigned and monotonic. tmux never
#     reuses a retired id, and freezing retires the ids of the panes it kills —
#     so the panes a thaw creates necessarily carry new ones (%2/%3 come back as
#     %6/%7). Comparing the raw string asserts that tmux will reissue a retired
#     id, which no implementation can satisfy.
# FR2.1 promises "same count, same layout" — layout means GEOMETRY, not
# identity. So both halves stay strict: every cell's dimensions AND offsets must
# match exactly, and so must the number of leaves.
_layout_geometry() { # <layout> -> geometry only: no checksum, no pane ids
  printf '%s' "${1#*,}" | sed -E 's/([0-9]+x[0-9]+,[0-9]+,[0-9]+),[0-9]+/\1/g'
}
_layout_panes() { # <layout> -> number of LEAF cells (the cells that hold a pane)
  printf '%s' "$1" | grep -oE '[0-9]+x[0-9]+,[0-9]+,[0-9]+,[0-9]+' | grep -c .
}
LIVE_LAYOUT="$(_t display-message -p -t work:1 '#{window_layout}')"
LIVE_GEOM="$(_layout_geometry "$LIVE_LAYOUT")"
REC_GEOM="$(_layout_geometry "$REC_LAYOUT")"
printf '    layout recorded: %s\n    layout live:     %s\n' "$REC_LAYOUT" "$LIVE_LAYOUT"
printf '    geometry recorded: %s\n    geometry live:     %s\n' "$REC_GEOM" "$LIVE_GEOM"
# Guard first: two empty strings compare equal, so a parse that silently yielded
# nothing would pass the geometry assertion for the worst possible reason.
assert_ne "the live layout has a geometry to compare" "$LIVE_GEOM" ""
assert_eq "the recorded layout's geometry was applied" "$LIVE_GEOM" "$REC_GEOM"
assert_eq "the layout holds the recorded number of panes" \
  "$(_layout_panes "$LIVE_LAYOUT")" "$(_layout_panes "$REC_LAYOUT")"

# The window is no longer a tombstone (AC3's user-visible half).
assert_hasnt "no pane still carries a ❄ tombstone title" "$(_titles_of work:1)" "$(printf '\xe2\x9d\x84 FROZEN')"
# The claim must be cleared, or a later `freeze` would see claim + verified
# state + N>1 panes and take §3.1.1's resume-from-kill branch, killing the panes
# this thaw just rebuilt.
assert_eq "the @cc-frozen claim is cleared" "$(_frozen_opt work:1)" ""

# Pending resumes: one per ROLE=primary sid, keyed by the NEW pane ids.
echo "    pending files:"
for f in $(_pending_files); do printf '      %s -> %s\n' "${f##*/}" "$(cat "$f")"; done
assert_eq "exactly 2 non-empty pending files" "$(_pending_count)" "2"
UNKEYED=0
for f in $(_pending_files); do
  base="${f##*/}"
  _t list-panes -t work:1 -F '#{pane_id}' | sed 's/^%//' | grep -qx "${base#%}" || UNKEYED=$((UNKEYED+1))
done
assert_eq "every pending file is keyed by a CURRENT pane id of the window" "$UNKEYED" "0"

ALL_PENDING="$(cat $(_pending_files) 2>/dev/null)"
assert_has "the claude session is resumed"   "$ALL_PENDING" "--resume $SID_CLAUDE"
assert_has "the claudish session is resumed" "$ALL_PENDING" "--resume $SID_CLAUDISH"

# ── 3. AC15 — the claudish pane relaunches through claudish ──────────────────
echo ""
echo "[3] AC15: the claudish pane relaunches via claudish with its recorded flags"
CLAUDISH_PENDING=""
for f in $(_pending_files); do
  case "$(cat "$f")" in *"--resume $SID_CLAUDISH"*) CLAUDISH_PENDING="$(cat "$f")" ;; esac
done
CLAUDE_PENDING=""
for f in $(_pending_files); do
  case "$(cat "$f")" in *"--resume $SID_CLAUDE"*) CLAUDE_PENDING="$(cat "$f")" ;; esac
done
printf '    claudish pending: [%s]\n    claude pending:   [%s]\n' "$CLAUDISH_PENDING" "$CLAUDE_PENDING"
assert_has   "the claudish command runs claudish"        "$CLAUDISH_PENDING" "claudish"
assert_has   "it carries the recorded model flag"        "$CLAUDISH_PENDING" "--model cx@gpt-5.6-sol"
assert_has   "it carries the recorded -d flag"           "$CLAUDISH_PENDING" "-d"
assert_hasnt "it is NEVER a plain 'claude --resume'"     "$CLAUDISH_PENDING" "claude --resume"
assert_ne    "the two panes got different commands"      "$CLAUDISH_PENDING" "$CLAUDE_PENDING"
assert_hasnt "the claudish sid did not leak into the claude pane" "$CLAUDE_PENDING" "$SID_CLAUDISH"

# ── 4. §3.2.9 — the state file survives the thaw, marked thawed ──────────────
echo ""
echo "[4] §3.2.9: the entry stays until a save confirms the sids are live again"
SF_AFTER="$(_state_path "$KEY")"
if [ -n "$SF_AFTER" ] && [ -s "$SF_AFTER" ]; then
  ok "the state file is still present after a successful thaw"
  assert_ne "a thawed_at line was appended" "$(_scalar "$SF_AFTER" thawed_at)" ""
  assert_eq "the recorded sids are untouched" \
    "$(awk -F'\t' '$1=="sid"' "$SF_AFTER" | wc -l | tr -d ' ')" "2"
else
  no "the state file is still present after a successful thaw" \
     "it was deleted — AC3 says 'removed', §3.2.9 says 'kept with thawed_at' (see header)"
fi

# ── 5. AC10 — thawing a window that is not frozen ────────────────────────────
echo ""
echo "[5] AC10/§3.2.1: thawing an already-thawed window is a no-op that succeeds"
PENDING_BEFORE="$(_pending_count)"
LAYOUT_BEFORE="$(_t display-message -p -t work:1 '#{window_layout}')"
OUT="$(_thaw thaw --no-save work:1 2>/dev/null)"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "exit code 0"                 "$RC" "0"
assert_eq "verb is NOTFROZEN"           "$(_field "$OUT" 1)" "NOTFROZEN"
assert_eq "pane count unchanged"        "$(_pane_count work:1)" "3"
assert_eq "layout unchanged"            "$(_t display-message -p -t work:1 '#{window_layout}')" "$LAYOUT_BEFORE"
assert_eq "no extra resume was queued"  "$(_pending_count)" "$PENDING_BEFORE"

# ── 6. AC12 — a thaw that fails midway loses nothing ─────────────────────────
echo ""
echo "[6] AC12: an interrupted thaw leaves the window frozen and the state intact"
CLAUDE2_PID=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
  CLAUDE2_PID="$(_find_desc work:2 "$BIN/claude" || true)"
  [ -n "$CLAUDE2_PID" ] && break
  sleep 0.4
done
if [ -n "$CLAUDE2_PID" ]; then ok "window 2's claude process is live ($CLAUDE2_PID)"
else no "window 2's claude process is live"; fi
[ -n "$CLAUDE2_PID" ] && echo "$SID_FAILHALF" > "$PD/by-pid/$CLAUDE2_PID.session-id"

OUT="$(_freeze freeze --no-save work:2 2>/dev/null)"; RC=$?
printf '    freeze exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "window 2 froze"        "$(_field "$OUT" 1)" "FROZE"
KEY2="$(_field "$OUT" 3)"
SF2="$(_state_path "$KEY2")"
if [ -z "$SF2" ] || [ ! -s "$SF2" ]; then
  no "window 2 has a state file" "nothing to test AC12 against"
else
  TOMB2="$(_t list-panes -t work:2 -F '#{pane_id}' | head -1)"
  [ -n "$TOMB2" ] || TOMB2="__nopane__"
  TOMB2_TITLE="$(_t display-message -p -t "$TOMB2" '#{pane_title}' 2>/dev/null || true)"
  for stage in split pending; do
    echo "    -- CC_FAIL_AFTER=$stage --"
    SUM_BEFORE="$(cksum < "$SF2")"
    PENDING_BEFORE="$(_pending_count)"
    OUT="$(CC_FAIL_AFTER="$stage" _thaw thaw --no-save work:2 2>/dev/null)"; RC=$?
    printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
    assert_eq "$stage: verb is FAILED"                "$(_field "$OUT" 1)" "FAILED"
    assert_eq "$stage: exit code 2"                   "$RC" "2"
    assert_eq "$stage: the state file is byte-identical" "$(cksum < "$SF2" 2>/dev/null)" "$SUM_BEFORE"
    assert_eq "$stage: the window is re-collapsed to 1 pane" "$(_pane_count work:2)" "1"
    assert_has "$stage: the tombstone title is back" "$(_titles_of work:2)" "$(printf '\xe2\x9d\x84 FROZEN %s' "$KEY2")"
    assert_eq "$stage: the window still claims its key" "$(_frozen_opt work:2)" "$KEY2"
    assert_eq "$stage: no half-queued resume was left behind" "$(_pending_count)" "$PENDING_BEFORE"
  done

  # "No data loss" is only proven if the window can still be thawed afterwards.
  echo "    -- recovery --"
  OUT="$(_thaw thaw --no-save work:2 2>/dev/null)"; RC=$?
  printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
  assert_eq "after two failed thaws the window still thaws" "$(_field "$OUT" 1)" "THAWED"
  assert_eq "recovery exit code 0"     "$RC" "0"
  assert_eq "both panes are back"      "$(_pane_count work:2)" "2"
  assert_has "the recorded session is queued at last" "$(cat $(_pending_files) 2>/dev/null)" "--resume $SID_FAILHALF"
fi

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
