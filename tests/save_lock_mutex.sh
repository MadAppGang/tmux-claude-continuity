#!/usr/bin/env bash
# save_lock_mutex.sh — the reclaimable lock (Bug A) and the save mutex (Bug B).
#
# ── WHAT WENT WRONG, AND WHAT THIS FILE PINS DOWN ────────────────────────────
#
# BUG A. `~/.config/tmux-cc/frozen/default/.lock` was found held and EMPTY on
# the live machine twice — once for ~20 minutes, once for 14 hours — with no
# live worker, and had to be `rmdir`'d by hand. `.lock` is the lock ROOT, and
# `cc_store_ns_dir` (cc_store.sh:28) creates it with `mkdir -p` on EVERY store
# access: it is created by a path that never goes through `_cc_lock_take`, so it
# never has an owner file and is never released. That is the ownerless directory
# that was observed. The library now says so, refuses any lock NAME that could
# resolve back to the root, and refuses to `rm -rf` the root in a reclaim (which
# would delete every live sibling lock at once).
#
# The reclaim rules themselves are what these tests exercise, because the old
# ones had the mirror-image bug: `kill -0 pid && age <= 300` meant a LIVE worker
# holding a lock for more than five minutes had it STOLEN — the naive age-based
# timeout. Identity is now established by process START TIME, so "alive" is
# checked against the process that actually took the lock and not merely against
# whatever now owns that pid number.
#
# BUG B. tmux runs continuum's check every 5 s; a save on the live machine took
# ~20 s. resurrect names its snapshot with ONE SECOND of resolution and builds
# it with `>` then three `>>`s, so overlapping saves interleave: measured, 146
# pane rows for 73 live panes (every row doubled), others with `panes=36
# windows=0` (truncated), 8 of 24 recent snapshots doubled, and 37
# continuum_save.sh + 18 save.sh + 3 pre_save.sh alive at once.
#
# ── ISOLATION ────────────────────────────────────────────────────────────────
# Own tmux socket, `-f /dev/null` on every invocation, every path under /tmp,
# EXIT-trap teardown that kills the server and reaps fixtures. The save burst
# drives the REAL tmux-resurrect save.sh, so tests/lib/resurrect_guard.sh is
# armed and `@resurrect-dir` is verified from the SERVER before a save runs.
#
# Usage: bash tests/save_lock_mutex.sh   (exit 0 = pass)

set -uo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session lk _seed

SOCKET="cclk$$"
TD="/tmp/cclk-$$"
RD="$TD/resurrect"
FD="$TD/frozen"
PD="$TD/panes"
LD="$TD/launch"
QD="$TD/pending"
SHIM="$TD/shim"
FIX="$TD/fix"
LOG="$TD/cc.log"
LOCKROOT="$TD/lockroot"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PRE_SAVE="$SCRIPT_DIR/pre_save.sh"
DRV="$TD/lockdrv.sh"

TMUX_CMD_STR="tmux -L $SOCKET -f /dev/null"
REAL_TMUX="$(command -v tmux 2>/dev/null)"
RESURRECT_SAVE=""
for _c in "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" \
          "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tmux-resurrect/scripts/save.sh"; do
  [ -x "$_c" ] && { RESURRECT_SAVE="$_c"; break; }
done

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
  cclk*) ;;
  *) echo "ABORT: [$SOCKET] is not this test's socket"; exit 1 ;;
esac
case "$TMUX_CMD_STR" in *"-L $SOCKET"*) ;; *) echo "ABORT: TMUX_CMD not on the test socket"; exit 1 ;; esac
case "$TMUX_CMD_STR" in *"-f /dev/null"*) ;; *) echo "ABORT: TMUX_CMD lacks -f /dev/null"; exit 1 ;; esac
case "$TD" in /tmp/*) ;; *) echo "ABORT: temp root [$TD] is not under /tmp"; exit 1 ;; esac
for d in "$RD" "$FD" "$PD" "$QD" "$LOCKROOT"; do
  case "$d" in "$HOME"/*) echo "ABORT: [$d] is inside \$HOME"; exit 1 ;; esac
done
[ -n "$REAL_TMUX" ] || { echo "ABORT: no tmux on PATH"; exit 1; }
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
_teardown_guarded() { _teardown; cc_warn_on_resurrect_leak || exit 1; }
trap _teardown_guarded EXIT INT TERM

mkdir -p "$RD" "$FD" "$PD/by-pid" "$LD" "$QD" "$SHIM" "$FIX" "$LOCKROOT"

# ── The lock driver ──────────────────────────────────────────────────────────
# Sources the REAL library and calls the REAL entry points. Nothing here
# reimplements the protocol; every verdict below comes from cc_common.sh.
cat > "$DRV" <<DRVEOF
#!/usr/bin/env bash
set -u
TMUX_CMD="\${TMUX_CMD:-tmux}"
. "$LIB_DIR/cc_common.sh"
mode="\$1"; root="\${2:-}"; name="\${3:-}"
case "\$mode" in
  hold)
    # Take the lock, announce the fact and the owning pid, then block forever on
    # a writer-less FIFO: no polling, no churn, and a pid that stays put.
    if _cc_lock_acquire "\$root" "\$name"; then
      printf 'TAKEN %s\n' "\$\$" > "\$4"
      read -r _x < "\$5"
    else
      printf 'BUSY %s\n' "\$\$" > "\$4"
    fi ;;
  try)
    if _cc_lock_acquire "\$root" "\$name"; then printf 'TAKEN\n'; else printf 'BUSY\n'; fi ;;
  token)
    _cc_proc_start_token "\$2" ;;
  serverpid)
    _cc_lock_server_pid ;;
  take-unwritable)
    # _cc_lock_take against a lock dir whose owner file CANNOT be created (the
    # name is already a directory). It must refuse to hold the lock and must
    # leave nothing behind — an unstamped lock is the wedge.
    d="\$root/\$name"
    mkdir -p "\$d/owner"
    if _cc_lock_take "\$d" 0 "\$(_cc_now)" "-"; then printf 'HELD\n'; else printf 'REFUSED\n'; fi
    [ -e "\$d" ] && printf 'LEFTOVER\n' || printf 'CLEAN\n' ;;
esac
DRVEOF
chmod +x "$DRV"
_drv() { bash "$DRV" "$@"; }

echo "=================================================================="
echo "  save_lock_mutex.sh"
echo "=================================================================="

# ═════════════════════════════════════════════════════════════════════════════
# A tmux server, so the lock's recorded server pid is a real one and the
# server-identity rail is exercised against a real value rather than 0.
# ═════════════════════════════════════════════════════════════════════════════
_t new-session -d -s lk -c /tmp
_t set-option -g base-index 1 >/dev/null
_t set-option -g pane-base-index 1 >/dev/null
_t set-option -g default-shell /bin/sh >/dev/null
_t set-option -g @resurrect-dir                  "$RD" >/dev/null
_t set-option -g @claude-continuity-panes-dir    "$PD" >/dev/null
_t set-option -g @claude-continuity-launch-dir   "$LD" >/dev/null
_t set-option -g @claude-continuity-pending-dir  "$QD" >/dev/null
_t set-option -g @claude-continuity-log-file     "$LOG" >/dev/null
_t set-option -g @claude-continuity-freeze-dir   "$FD" >/dev/null
_t set-option -g @resurrect-hook-post-save-layout "$PRE_SAVE \"\$1\"" >/dev/null
# Mirror production: tmux-claude-continuity.tmux registers BOTH hooks. Without
# the post-save-all one this test measured only the :246 guards, which the design
# says can never close the last third of the `last`-goes-dangling window — and
# that is exactly what showed up here as a 1-in-3 flake.
_t set-option -g @resurrect-hook-post-save-all "$PRE_SAVE --verify-last" >/dev/null
cc_guard_resurrect_dir "$RD" tmux -L "$SOCKET" -f /dev/null

export TMUX_CMD="$TMUX_CMD_STR"
export CC_FREEZE_DIR="$FD"
export CC_LOG_FILE="$LOG"

SERVER_PID="$(_drv serverpid)"
printf '  tmux server pid: %s\n' "$SERVER_PID"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[0] THE OWNER RECORD: four non-empty fields, and the root is not a lock"
# ═════════════════════════════════════════════════════════════════════════════
mkfifo "$FIX/f0"
_drv hold "$LOCKROOT" l0 "$FIX/r0" "$FIX/f0" & H0=$!
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$FIX/r0" ] && break; sleep 0.1
done
R0="$(cat "$FIX/r0" 2>/dev/null)"
H0PID="${R0#TAKEN }"
assert_has "the driver took the lock" "$R0" "TAKEN"
OWNER0="$(cat "$LOCKROOT/l0/owner" 2>/dev/null)"
printf '    owner record: [%s]\n' "$(printf '%s' "$OWNER0" | tr '\t' '|')"
assert_eq "the owner record has four TAB fields" \
  "$(printf '%s' "$OWNER0" | awk -F'\t' '{print NF}')" "4"
assert_eq "no field is empty" \
  "$(printf '%s' "$OWNER0" | awk -F'\t' '{for(i=1;i<=NF;i++) if($i=="") e++} END{print e+0}')" "0"
assert_eq "field 1 is the holder's pid" \
  "$(printf '%s' "$OWNER0" | cut -f1)" "$H0PID"
assert_eq "field 2 is this tmux server's pid" \
  "$(printf '%s' "$OWNER0" | cut -f2)" "$SERVER_PID"
assert_eq "field 4 is the holder's process start token" \
  "$(printf '%s' "$OWNER0" | cut -f4)" "$(_drv token "$H0PID")"

# A lock NAME that could resolve back to the root is refused outright: the
# reclaim path ends in `rm -rf`, and the root is the container of every live
# sibling lock.
assert_eq "an empty lock name is refused, not taken"      "$(_drv try "$LOCKROOT" '')" "BUSY"
assert_eq "a lock name containing '/' is refused"         "$(_drv try "$LOCKROOT" 'a/b')" "BUSY"
assert_eq "a lock name of '..' is refused"                "$(_drv try "$LOCKROOT" '..')" "BUSY"
assert_eq "the live sibling lock survived every refusal"  "$(cat "$LOCKROOT/l0/owner" 2>/dev/null)" "$OWNER0"
printf '%s\n' x > "$FIX/f0" 2>/dev/null &
wait "$H0" 2>/dev/null

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[1] STALE RECLAIM: SIGKILL the holder; the next caller proceeds"
# ═════════════════════════════════════════════════════════════════════════════
mkfifo "$FIX/f1"
: > "$FIX/r1"
_drv hold "$LOCKROOT" l1 "$FIX/r1" "$FIX/f1" & H1=$!
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$FIX/r1" ] && break; sleep 0.1
done
R1="$(cat "$FIX/r1")"; H1PID="${R1#TAKEN }"
assert_has "holder took the lock" "$R1" "TAKEN"
assert_eq  "a second caller is BUSY while the holder lives" "$(_drv try "$LOCKROOT" l1)" "BUSY"
kill -9 "$H1PID" 2>/dev/null
wait "$H1" 2>/dev/null
# SIGKILL runs no trap, so the lock directory is still on disk.
assert_eq "the lock directory outlived the SIGKILLed holder" \
  "$([ -d "$LOCKROOT/l1" ] && echo yes || echo no)" "yes"
kill -0 "$H1PID" 2>/dev/null && sleep 0.5
# Bounded, so "proceeds" is proven and not merely "did not obviously hang".
T1="$( (bash "$DRV" try "$LOCKROOT" l1) & _p=$!; \
      ( sleep 10; kill -9 "$_p" 2>/dev/null ) 2>/dev/null & _w=$!; \
      wait "$_p" 2>/dev/null; kill "$_w" 2>/dev/null )"
assert_eq "the next caller RECLAIMS a dead holder's lock (does not hang)" "$T1" "TAKEN"
assert_has "the reclaim is logged with its reason" "$(cat "$LOG" 2>/dev/null)" "LOCK-RECLAIM l1: owner pid $H1PID is dead"
rm -rf "$LOCKROOT/l1"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[2] OWNERLESS RECLAIM: a lock directory with NO owner file"
# ═════════════════════════════════════════════════════════════════════════════
# Exactly the state observed on the live machine.
mkdir -p "$LOCKROOT/l2"
assert_eq "the fixture really has no owner file" \
  "$([ -e "$LOCKROOT/l2/owner" ] && echo yes || echo no)" "no"
# Inside the grace it is BUSY: a taker may be between mkdir(2) and its printf
# this instant, and stealing there would break the live-holder property.
assert_eq "inside the orphan grace it reports BUSY (a taker may be mid-write)" \
  "$(CC_LOCK_ORPHAN_GRACE_SECS=30 _drv try "$LOCKROOT" l2)" "BUSY"
assert_eq "and it was NOT stolen" "$([ -e "$LOCKROOT/l2/owner" ] && echo yes || echo no)" "no"
sleep 2
assert_eq "past the grace it is RECLAIMED" \
  "$(CC_LOCK_ORPHAN_GRACE_SECS=1 _drv try "$LOCKROOT" l2)" "TAKEN"
assert_has "the ownerless reclaim is logged" "$(cat "$LOG" 2>/dev/null)" "LOCK-RECLAIM l2: no owner file"
rm -rf "$LOCKROOT/l2"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[3] LIVE HOLDER PROTECTED: no age can steal a confirmed-live lock"
# ═════════════════════════════════════════════════════════════════════════════
mkfifo "$FIX/f3"
: > "$FIX/r3"
_drv hold "$LOCKROOT" l3 "$FIX/r3" "$FIX/f3" & H3=$!
for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$FIX/r3" ] && break; sleep 0.1
done
R3="$(cat "$FIX/r3")"; H3PID="${R3#TAKEN }"
OWNER3="$(cat "$LOCKROOT/l3/owner" 2>/dev/null)"
assert_has "holder took the lock" "$R3" "TAKEN"
sleep 2
# THE ANTI-NAIVE-TIMEOUT ASSERTION. Both knobs are set to values under which any
# age-based rule fires: the stale window is 1 s and the lock is >= 2 s old, and
# the second caller's clock is pushed a week into the future so the computed age
# is ~604800 s. The old rule (`kill -0 pid && age <= 300`) stole the lock here.
assert_eq "stale window 1s, lock 2s old -> STILL BUSY" \
  "$(CC_LOCK_STALE_SECS=1 _drv try "$LOCKROOT" l3)" "BUSY"
assert_eq "clock pushed +1 week, stale window 1s -> STILL BUSY" \
  "$(CC_NOW=$(( $(date +%s) + 604800 )) CC_LOCK_STALE_SECS=1 _drv try "$LOCKROOT" l3)" "BUSY"
assert_eq "the owner record is untouched (nothing was stolen)" \
  "$(cat "$LOCKROOT/l3/owner" 2>/dev/null)" "$OWNER3"
assert_eq "the holder is still alive" "$(kill -0 "$H3PID" 2>/dev/null && echo yes || echo no)" "yes"
# NEGATIVE CONTROLS. Each one is the SAME live pid and the same age as the
# protected case above, differing in exactly one recorded field. If these did
# not flip to TAKEN, the BUSY verdicts above would prove nothing — a rule that
# can never reclaim is as broken as one that always does.
# (`try` releases on exit, so each control re-creates the lock directory.)
_plant_owner() { mkdir -p "$LOCKROOT/l3"; printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > "$LOCKROOT/l3/owner"; }

_plant_owner "$H3PID" "$SERVER_PID" "$(date +%s)" "Not_The_Same_Process_1970"
assert_eq "same live pid but a MISMATCHED start token -> reclaimed (pid reuse)" \
  "$(_drv try "$LOCKROOT" l3)" "TAKEN"
assert_has "the recycle is named in the log" "$(cat "$LOG" 2>/dev/null)" "was RECYCLED"

_plant_owner "$$" "999999" "$(date +%s)" "$(_drv token $$)"
assert_eq "an owner stamped by a DIFFERENT tmux server -> reclaimed" \
  "$(_drv try "$LOCKROOT" l3)" "TAKEN"
assert_has "the server mismatch is named in the log" "$(cat "$LOG" 2>/dev/null)" "belongs to tmux server 999999"

# A LEGACY three-field owner file (no start token) is unconfirmable, so and only
# so does age decide: fresh -> BUSY, past the stale window -> reclaimed.
_plant_owner "$$" "$SERVER_PID" "$(date +%s)" ""
printf '%s\t%s\t%s\n' "$$" "$SERVER_PID" "$(date +%s)" > "$LOCKROOT/l3/owner"
assert_eq "a fresh legacy owner file is still BUSY" \
  "$(CC_LOCK_STALE_SECS=300 _drv try "$LOCKROOT" l3)" "BUSY"
printf '%s\t%s\t%s\n' "$$" "$SERVER_PID" "$(( $(date +%s) - 400 ))" > "$LOCKROOT/l3/owner"
assert_eq "a legacy owner file past the stale window IS reclaimed" \
  "$(CC_LOCK_STALE_SECS=300 _drv try "$LOCKROOT" l3)" "TAKEN"
printf '%s\n' x > "$FIX/f3" 2>/dev/null &
wait "$H3" 2>/dev/null
rm -rf "$LOCKROOT/l3"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[4] CRASH WINDOW: killed between mkdir(2) and the owner write"
# ═════════════════════════════════════════════════════════════════════════════
# CC_LOCK_FAIL_AFTER=mkdir makes _cc_lock_acquire SIGKILL itself the instant the
# mutex exists and before the owner record is written, so the ownerless state
# under test is produced by the REAL acquisition path.
CC_LOCK_FAIL_AFTER=mkdir _drv try "$LOCKROOT" l4 >/dev/null 2>&1
assert_eq "the crashed worker left the lock directory behind" \
  "$([ -d "$LOCKROOT/l4" ] && echo yes || echo no)" "yes"
assert_eq "and it has no owner file" \
  "$([ -e "$LOCKROOT/l4/owner" ] && echo yes || echo no)" "no"
assert_eq "inside the grace, the crash-window lock is BUSY" \
  "$(CC_LOCK_ORPHAN_GRACE_SECS=30 _drv try "$LOCKROOT" l4)" "BUSY"
sleep 2
assert_eq "past the grace it is reclaimable — the crash cannot wedge the store" \
  "$(CC_LOCK_ORPHAN_GRACE_SECS=1 _drv try "$LOCKROOT" l4)" "TAKEN"
rm -rf "$LOCKROOT/l4"

# The other half of the window: the owner write FAILING must not leave a lock.
OUT_UW="$(_drv take-unwritable "$LOCKROOT" l4b)"
assert_has "an unstampable lock is REFUSED, not held" "$OUT_UW" "REFUSED"
assert_has "and nothing is left behind for the next caller to trip over" "$OUT_UW" "CLEAN"
rm -rf "$LOCKROOT/l4b"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[7] ANTI-VACUITY: the doubled/truncated detector must actually fire"
# ═════════════════════════════════════════════════════════════════════════════
# Run FIRST, so that if the detector is broken the burst assertions below cannot
# quietly pass on a check that never fires. `pre_save.sh --check` is the same
# function the save path uses; there is no second implementation.
_mkpane() { printf 'pane\tlk\t%s\t1\t:*\t%s\ttitle\t:/tmp\t1\tsh\t:sh\n' "$1" "$2"; }
_mkwin()  { printf 'window\tlk\t%s\twin%s\t1\t:*\tabcd,80x24,0,0,0\t:\n' "$1" "$1"; }
{ _mkpane 1 1; _mkpane 1 2; _mkpane 2 1; _mkwin 1; _mkwin 2; printf 'state\tlk\tlk\n'; } > "$FIX/good.txt"
cat "$FIX/good.txt" "$FIX/good.txt" > "$FIX/doubled.txt"
grep -v '^window' "$FIX/good.txt" > "$FIX/nowin.txt"
grep -v '^state'  "$FIX/good.txt" > "$FIX/nostate.txt"
{ cat "$FIX/good.txt"; printf 'state\tlk\tlk2\n'; } > "$FIX/twostate.txt"
# A DIFFERENT pane row for the same (session,window,pane) key: doubling that a
# whole-line comparison alone would miss.
{ cat "$FIX/good.txt"; printf 'pane\tlk\t1\t1\t:*\t1\tOTHER\t:/tmp\t1\tsh\t:sh\n'; } > "$FIX/dupkey.txt"

_check() { bash "$PRE_SAVE" --check "$1" 2>/dev/null; }
V_GOOD="$(_check "$FIX/good.txt")";     bash "$PRE_SAVE" --check "$FIX/good.txt" >/dev/null 2>&1; RC_GOOD=$?
V_DBL="$(_check "$FIX/doubled.txt")";   bash "$PRE_SAVE" --check "$FIX/doubled.txt" >/dev/null 2>&1; RC_DBL=$?
printf '    good=[%s] doubled=[%s]\n' "$V_GOOD" "$V_DBL"
assert_has "a healthy snapshot reports OK"                 "$V_GOOD" "OK panes=3 windows=2 state=1"
assert_eq  "and --check exits 0 on it"                     "$RC_GOOD" "0"
assert_has "a DELIBERATELY DOUBLED snapshot reports DOUBLED" "$V_DBL" "DOUBLED"
assert_eq  "and --check exits 1 on it"                     "$RC_DBL" "1"
assert_has "a doubled snapshot names the duplicated pane keys" "$V_DBL" "dup_pane=3"
assert_has "a re-keyed duplicate pane row is caught too"   "$(_check "$FIX/dupkey.txt")" "dup_pane=1"
assert_has "panes>0 windows=0 reports TRUNCATED"           "$(_check "$FIX/nowin.txt")" "TRUNCATED panes=3 windows=0"
assert_has "a missing state row reports TRUNCATED"         "$(_check "$FIX/nostate.txt")" "state_rows=0"
assert_has "two state rows report TRUNCATED"               "$(_check "$FIX/twostate.txt")" "state_rows=2"
assert_has "an empty file reports EMPTY"                   "$(_check /dev/null)" "EMPTY"

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[5/6] CONCURRENT AND SUSTAINED SAVES (real tmux-resurrect save.sh)"
# ═════════════════════════════════════════════════════════════════════════════
if [ -z "$RESURRECT_SAVE" ]; then
  no "tmux-resurrect save.sh is available to drive" "checked ~/.tmux/plugins and XDG config"
else
  # save.sh calls a bare `tmux`. A PATH shim pins every one of those calls to
  # THIS socket; without it the save would dump the user's real server into the
  # test's resurrect directory (and read the user's real options).
  printf '#!/bin/sh\nexec %s -L %s -f /dev/null "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"
  chmod +x "$SHIM/tmux"
  assert_eq "the shim pins save.sh to the test socket" \
    "$(PATH="$SHIM:$PATH" tmux display-message -p '#{pid}')" "$SERVER_PID"

  # A layout worth dumping: 4 windows, 7 panes.
  _t new-window -d -t lk -c /tmp
  _t new-window -d -t lk -c /tmp
  _t new-window -d -t lk -c /tmp
  _t split-window -d -t lk:1 -c /tmp
  _t split-window -d -t lk:2 -c /tmp
  _t split-window -d -t lk:3 -c /tmp
  LIVE_PANES="$(_t list-panes -a -F x | grep -c . | tr -d ' ')"
  LIVE_WINS="$(_t list-windows -a -F x | grep -c . | tr -d ' ')"
  printf '    live layout: %s panes in %s windows\n' "$LIVE_PANES" "$LIVE_WINS"

  _save() { PATH="$SHIM:$PATH" "$RESURRECT_SAVE" quiet >/dev/null 2>&1; }
  _snapcount() { ls "$RD"/tmux_resurrect_*.txt 2>/dev/null | grep -c . | tr -d ' '; }
  # `last` is legitimately EITHER a symlink or a regular file. The integrity
  # guard's IDENTITY lever replaces the symlink with a regular-file copy on
  # purpose, so that save.sh's `rm` of the .txt cannot leave `last` dangling.
  # Resolving with readlink alone reports every one of those successful runs as
  # "last is missing" — the oracle cannot see the very outcome it is testing.
  _lastfile() {
    [ -e "$RD/last" ] || return 0
    if [ -L "$RD/last" ]; then
      local b; b="$(readlink "$RD/last" 2>/dev/null)"
      [ -n "$b" ] && printf '%s' "$RD/$b"
    else
      printf '%s' "$RD/last"
    fi
  }

  # A first, uncontended save so `last` exists and the neutralise path has a
  # complete snapshot to fall back to.
  _save
  L0="$(_lastfile)"
  assert_ne "a baseline save produced a snapshot and repointed 'last'" "${L0:-}" ""
  assert_has "the baseline snapshot is complete" "$(_check "${L0:-/dev/null}")" "OK"
  assert_eq  "it records every live pane" \
    "$(awk -F'\t' '$1=="pane"' "${L0:-/dev/null}" | grep -c . | tr -d ' ')" "$LIVE_PANES"

  # Give the burst something genuinely new to record. Without this the dump is
  # byte-identical to `last`, and vanilla resurrect deletes an identical dump on
  # its own (`files_differ` is false at save.sh:247) — so "no new snapshot" would
  # be ordinary deduplication rather than anything the mutex did, and the
  # assertion below could never distinguish the two. Changing the layout first
  # makes "exactly one new file" the only correct outcome.
  _t new-window -d -t lk -c /tmp
  LIVE_PANES="$(_t list-panes -a -F x | grep -c . | tr -d ' ')"
  LIVE_WINS="$(_t list-windows -a -F x | grep -c . | tr -d ' ')"
  sleep 1.1   # resurrect names snapshots to the second; force a distinct filename
  printf '    layout changed before the burst: %s panes in %s windows\n' "$LIVE_PANES" "$LIVE_WINS"

  echo ""
  echo "  [5] ten save.sh fired simultaneously"
  BEFORE_N="$(_snapcount)"
  : > "$TD/rcs"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( _save; printf '%s\n' "$?" >> "$TD/rcs" ) &
  done
  wait
  AFTER_N="$(_snapcount)"
  NEW_N=$((AFTER_N - BEFORE_N))
  RC_BAD="$(grep -cv '^0$' "$TD/rcs" | tr -d ' ')"
  L5="$(_lastfile)"
  V5="$(_check "${L5:-/dev/null}")"
  printf '    snapshots before=%s after=%s (new=%s); non-zero exits=%s\n' \
    "$BEFORE_N" "$AFTER_N" "$NEW_N" "$RC_BAD"
  printf '    last -> %s : %s\n' "$(basename "${L5:-none}")" "$V5"
  # WHICH CONTRACT APPLIES HERE. This burst invokes tmux-resurrect's save.sh
  # DIRECTLY — the foreign callers, tmux-continuum's timer and the manual key
  # binding. resurrect has no pre-save hook, so nothing can stop those processes
  # DUMPING concurrently into the same one-second filename; a post-save hook can
  # only decide what gets PUBLISHED. The enforceable contract for foreign callers
  # is therefore "`last` is never left corrupt or dangling", NOT "every update
  # lands". Demanding a new snapshot here would assert something the design
  # openly says it cannot deliver.
  #
  # The other half of the contract — that an update genuinely survives a burst —
  # is enforceable on the path the plugin owns, and is asserted in [5b] below
  # against `cc_freeze.sh save`, which takes the mutex BEFORE the dump.
  assert_eq  "all ten saves exited 0 (BUSY is not an error)" "$RC_BAD" "0"
  assert_ne  "'last' resolves to a real file" "${L5:-}" ""
  assert_has "the produced snapshot is neither doubled nor truncated" "$V5" "OK"
  if [ "$NEW_N" -le 1 ]; then
    ok "ten colliding foreign saves produced at most one new snapshot (got $NEW_N)"
  else
    no "ten colliding foreign saves produced at most one new snapshot" "got $NEW_N"
  fi
  # A dropped update must be OBSERVABLE. Silently discarding a save is the
  # failure mode that made this whole area hard to diagnose in the first place.
  if [ "$NEW_N" -eq 0 ]; then
    if grep -qE 'SAVE-BUSY|SNAPSHOT-VETO' "$LOG" 2>/dev/null; then
      ok "when the burst published nothing, the log says why"
    else
      no "when the burst published nothing, the log says why" "no SAVE-BUSY/SNAPSHOT-VETO in the log"
    fi
  fi
  # Was there anything to defend against? If the burst never collided, the four
  # assertions above are weak — so say which mechanism fired.
  BUSY_N="$(grep -c 'SAVE-BUSY' "$LOG" 2>/dev/null | tr -d ' ')"
  REPAIR_N="$(grep -c 'SNAPSHOT-REPAIR' "$LOG" 2>/dev/null | tr -d ' ')"
  VETO_N="$(grep -c 'SNAPSHOT-VETO' "$LOG" 2>/dev/null | tr -d ' ')"
  printf '    mutex hits: SAVE-BUSY=%s  SNAPSHOT-REPAIR=%s  SNAPSHOT-VETO=%s\n' \
    "$BUSY_N" "$REPAIR_N" "$VETO_N"
  if [ "$((BUSY_N + REPAIR_N + VETO_N))" -gt 0 ]; then
    ok "the burst really did collide, and a named mechanism handled it"
  else
    no "the burst really did collide" "no SAVE-BUSY/REPAIR/VETO in the log: this run proves nothing about concurrency"
  fi

  echo ""
  echo "  [5b] ten cc_freeze.sh save fired simultaneously (the path we own)"
  # Unlike [5], this entry point takes the mutex BEFORE anything is dumped, so
  # the losers never write a byte and the winner's dump is uncontended. That
  # makes the strong assertion legitimate here: a real layout change made just
  # before the burst MUST survive it.
  _t new-window -d -t lk -c /tmp
  LIVE_PANES2="$(_t list-panes -a -F x | grep -c . | tr -d ' ')"
  LIVE_WINS2="$(_t list-windows -a -F x | grep -c . | tr -d ' ')"
  sleep 1.1
  BEFORE_N2="$(_snapcount)"
  : > "$TD/rcs2"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    ( PATH="$SHIM:$PATH" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" CC_SAVE_LOG="$LOG" \
        CC_SAVE_CMD="'$RESURRECT_SAVE' quiet" \
        bash "$SCRIPT_DIR/cc_freeze.sh" save >/dev/null 2>&1
      printf '%s\n' "$?" >> "$TD/rcs2" ) &
  done
  wait
  AFTER_N2="$(_snapcount)"
  NEW_N2=$((AFTER_N2 - BEFORE_N2))
  RC_BAD2="$(grep -cv '^0$' "$TD/rcs2" | tr -d ' ')"
  L5B="$(_lastfile)"
  V5B="$(_check "${L5B:-/dev/null}")"
  P5B="$(awk -F'\t' '$1=="pane"'   "${L5B:-/dev/null}" | grep -c . | tr -d ' ')"
  W5B="$(awk -F'\t' '$1=="window"' "${L5B:-/dev/null}" | grep -c . | tr -d ' ')"
  printf '    live now: %s panes / %s windows; new snapshots=%s; last=%s\n' \
    "$LIVE_PANES2" "$LIVE_WINS2" "$NEW_N2" "$V5B"
  assert_eq  "all ten serialised saves exited 0" "$RC_BAD2" "0"
  assert_eq  "exactly ONE new snapshot was produced" "$NEW_N2" "1"
  assert_has "it is neither doubled nor truncated" "$V5B" "OK"
  assert_eq  "the layout change SURVIVED the burst (panes)"   "$P5B" "$LIVE_PANES2"
  assert_eq  "the layout change SURVIVED the burst (windows)" "$W5B" "$LIVE_WINS2"

  echo ""
  echo "  [6] twenty consecutive saves"
  BAD=0; DOUBLED=0; TRUNC=0; MISSING=0
  i=0
  while [ "$i" -lt 20 ]; do
    i=$((i + 1))
    _save
    LF="$(_lastfile)"
    if [ -z "$LF" ] || [ ! -f "$LF" ]; then MISSING=$((MISSING + 1)); BAD=$((BAD + 1)); sleep 1.1; continue; fi
    V="$(_check "$LF")"
    case "$V" in
      OK*) ;;
      DOUBLED*)   DOUBLED=$((DOUBLED + 1)); BAD=$((BAD + 1)); printf '      #%s %s\n' "$i" "$V" ;;
      *)          TRUNC=$((TRUNC + 1));     BAD=$((BAD + 1)); printf '      #%s %s\n' "$i" "$V" ;;
    esac
    # The literal acceptance wording, re-derived here rather than trusted from
    # the verdict string: window rows > 0, exactly 1 state row, and window rows
    # equal to DISTINCT window rows.
    WR="$(awk -F'\t' '$1=="window"' "$LF" | grep -c . | tr -d ' ')"
    WD="$(awk -F'\t' '$1=="window" {print $2"\t"$3}' "$LF" | sort -u | grep -c . | tr -d ' ')"
    SR="$(awk -F'\t' '$1=="state"' "$LF" | grep -c . | tr -d ' ')"
    if [ "$WR" -le 0 ] || [ "$SR" -ne 1 ] || [ "$WR" -ne "$WD" ]; then
      BAD=$((BAD + 1)); printf '      #%s window_rows=%s distinct=%s state_rows=%s\n' "$i" "$WR" "$WD" "$SR"
    fi
    sleep 1.1
  done
  printf '    20 saves: doubled=%s truncated=%s missing-last=%s\n' "$DOUBLED" "$TRUNC" "$MISSING"
  assert_eq "0 doubled snapshots over 20 consecutive saves"   "$DOUBLED" "0"
  assert_eq "0 truncated snapshots over 20 consecutive saves" "$TRUNC" "0"
  assert_eq "'last' resolved to a complete snapshot every time" "$BAD" "0"
fi

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "[8] NO LEFTOVER LOCK: the save mutex is released on every path"
# ═════════════════════════════════════════════════════════════════════════════
LEFT="$(ls "$RD/.cc-save-lock" 2>/dev/null | grep -c . | tr -d ' ')"
assert_eq "the save-lock root holds no lock after the runs" "$LEFT" "0"

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
