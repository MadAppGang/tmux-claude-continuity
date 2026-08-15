#!/usr/bin/env bash
# freeze_legacy_entry.sh — a WINDOW-keyed entry written by the PREVIOUS version
# (a97bff0) must still be readable and thawable.
#
# design-delta-tree, "Compatibility": "Existing WINDOW-keyed state files from
# a97bff0 must still be readable and thawable … a user who froze a window before
# upgrading must not be stranded."
#
# So this test writes the OLD store shape by hand — the format documented in
# architecture §2.3, which is what a97bff0 emitted — claims it the OLD way (the
# `@cc-frozen` option on the WINDOW, not on a pane), stages the window as the old
# model left it (collapsed to ONE tombstone pane), and then requires the CURRENT
# implementation to inventory it and thaw it back into its N panes.
#
# The old shape differs from the new one in exactly the ways that matter:
#   * no `unit` line               (the new store declares `unit<TAB>pane`)
#   * `pane_count` is 3, not 1     (the entry describes a WINDOW's worth of panes)
#   * it carries `layout` and `active_pane`, which the pane model dropped
#   * the claim is a WINDOW option; the new model claims per pane
#   * the tombstone is ONE pane standing in for three
# A reader that only understands the new shape will either ignore the entry — the
# user is stranded, with three panes' worth of session ids unreachable — or
# mis-parse it. Both are caught here.
#
# Two entries are exercised, because §3.2's target grammar admits both spellings
# for a stored entry: one thawed by `session:index`, one thawed by `<key>`.
#
# Nothing is faked about the OUTCOME: the recorded cwds and titles are real
# directories and real strings, and the thaw is judged on the live server.
#
# Isolation: own tmux socket, `-f /dev/null` on EVERY tmux invocation, all state
# under /tmp, CC_TEST=1, CC_NO_NUDGE=1 so pending files stay on disk to be read.
#
# Usage: bash tests/freeze_legacy_entry.sh   (exit 0 = pass)

set -uo pipefail

# ── RESURRECT SAVE-SIDE ISOLATION ────────────────────────────────────────────
# RESURRECT_FILE redirects resurrect READS. Only @resurrect-dir redirects its
# WRITES. A test that triggers a save without setting it deposits fixture
# snapshots in the user's live resurrect directory and can leave `last`
# pointing at one. See tests/lib/resurrect_guard.sh for the measured damage.
. "$(cd "$(dirname "$0")" && pwd)/lib/resurrect_guard.sh" || {
  echo "ABORT: tests/lib/resurrect_guard.sh is missing"; exit 1; }
cc_register_test_session _seed work legacy alpha beta lvl cA cB cC cD cE

SOCKET="ccle$$"
TD="/tmp/ccle-$$"
FD="$TD/frozen"
PD="$TD/panes"
LD="$TD/launch"
QD="$TD/pending"
RD="$TD/resurrect"
LOG="$TD/cc.log"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
THAW="$SCRIPT_DIR/cc_thaw.sh"
POPUP="$SCRIPT_DIR/cc_popup.sh"

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
  ccle*) ;;
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
_teardown() { _t kill-server 2>/dev/null; rm -rf "$TD"; }
# Re-wrap the teardown so a leak into the real resurrect dir fails the run
# even on the early-abort paths that never reach the final assertions.
_cc_teardown_guarded() { _teardown; cc_warn_on_resurrect_leak || exit 1; }
trap _cc_teardown_guarded EXIT INT TERM

mkdir -p "$FD" "$PD/by-pid" "$LD" "$QD" "$RD" \
         "$TD/cwd-1" "$TD/cwd-2" "$TD/cwd-3" "$TD/cwd-k1" "$TD/cwd-k2"

MISSING=""
[ -f "$THAW" ]  || MISSING="$MISSING $THAW"
[ -f "$POPUP" ] || MISSING="$MISSING $POPUP"
if [ -n "$MISSING" ]; then
  echo "  FAIL: required script(s) missing:$MISSING"
  echo ""; echo "  Results: 0 passed, 1 failed"; exit 1
fi

# macOS resolves symlinked cwds (/tmp -> /private/tmp); record the resolved form
# or every cwd assertion fails for the wrong reason.
C1="$(cd "$TD/cwd-1" && pwd -P)"
C2="$(cd "$TD/cwd-2" && pwd -P)"
C3="$(cd "$TD/cwd-3" && pwd -P)"
K1="$(cd "$TD/cwd-k1" && pwd -P)"
K2="$(cd "$TD/cwd-k2" && pwd -P)"

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

# Two legacy tombstones and one ordinary awake window that must stay untouched.
_t new-session -d -s work -n oldwin -c /tmp
_t new-window  -t work:2 -n oldkey -c /tmp
_t new-window  -t work:3 -n awake  -c /tmp
_t split-window -t work:3 -c /tmp
_t kill-session -t _seed

NS="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NS" != "1" ]; then echo "ABORT: expected 1 session on the test socket, found $NS"; exit 1; fi

_b64()  { printf '%s' "$1" | base64 | tr -d '\n'; }
_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }
_pane_count() { _t list-panes -t "$1" 2>/dev/null | wc -l | tr -d ' '; }
_pane_id_at() { _t list-panes -t "$1" -F '#{pane_index} #{pane_id}' 2>/dev/null \
                  | awk -v i="$2" '$1==i { print $2; exit }'; }
_titles_of()  { _t list-panes -t "$1" -F '#{pane_title}' 2>/dev/null | tr '\n' '|'; }
_win_claim()  { _t show-options -w -t "$1" -v @cc-frozen 2>/dev/null || true; }
_pane_claim() { _t show-options -p -t "$1" -v @cc-frozen 2>/dev/null || true; }
_scalar()     { awk -F'\t' -v k="$2" '$1==k { print $2; exit }' "$1" 2>/dev/null; }
_col()        { printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NF>=2 { print $n; exit }'; }
_nrows()      { printf '%s\n' "$1" | grep -c . | tr -d ' '; }
_pending_files() { local f; for f in "$QD"/*; do [ -s "$f" ] && printf '%s\n' "$f"; done 2>/dev/null; }
_pending_count() { _pending_files | grep -c . | tr -d ' '; }

_thaw() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" CC_NO_SAVE=1 CC_NO_NUDGE=1 bash "$THAW" "$@"
}
_list() {
  CC_TEST=1 TMUX_CMD="$TMUX_CMD_STR" CC_FREEZE_DIR="$FD" CC_LOG_FILE="$LOG" \
  CC_NOW="$NOW" bash "$POPUP" --list "$@"
}

NS_DIR="$FD/$SOCKET"
mkdir -p "$NS_DIR"
SERVER_PID="$(_t display-message -p '#{pid}')"

# ── The a97bff0 store shape, written by hand (architecture §2.3) ─────────────
# One fact per line, TAB-separated, `v 1` first and `end 1` last; `pane` lines
# are geometry, `sid` lines are what to resume — one session per line.
_write_legacy_entry() { # <key> <window target> <window name> <sid> <cwd…>
  local key="$1" wt="$2" wname="$3" sid="$4"; shift 4
  local wid widx i cwd npanes first
  npanes="$#"; first="$1"
  wid="$(_t display-message -p -t "$wt" '#{window_id}')"
  widx="$(_t display-message -p -t "$wt" '#{window_index}')"
  {
    printf 'v\t1\n'
    printf 'key\t%s\n' "$key"
    printf 'frozen_at\t%s\n' "$((NOW - 3600))"
    printf 'reason\tmanual\n'
    printf 'idle_at_freeze\t218331\n'
    printf 'socket\t%s\n' "$SOCKET"
    printf 'server_pid\t%s\n' "$SERVER_PID"
    printf 'window_id\t%s\n' "$wid"
    printf 'session\t%s\n' "$(_b64 work)"
    printf 'window_index\t%s\n' "$widx"
    printf 'window_name\t%s\n' "$(_b64 "$wname")"
    # layout + active_pane: recorded by the OLD model for replay, dropped by the
    # new one. A reader that chokes on an unknown scalar fails here.
    printf 'layout\t80x24,0,0[80x12,0,0,0,80x5,0,13,1,80x5,0,19,2]\n'
    printf 'active_pane\t1\n'
    printf 'pane_count\t%s\n' "$npanes"
    printf 'sid_count\t1\n'
    printf 'claude_procs\t1\n'
    printf 'primary_cwd\t%s\n' "$(_b64 "$first")"
    printf 'rss_at_freeze\t5217382400\n'
    i=0
    for cwd in "$@"; do
      i=$((i+1))
      if [ "$i" = "1" ]; then
        printf 'pane\t%s\t;CWD=%s\t;TITLE=%s\t;CMD=%s\t;PID=9900%s\t;PPID=99000\t;CLASS=claude\n' \
          "$i" "$(_b64 "$cwd")" "$(_b64 "$key-pane-$i")" "$(_b64 '/bin/zsh')" "$i"
      else
        printf 'pane\t%s\t;CWD=%s\t;TITLE=%s\t;CMD=%s\t;PID=9900%s\t;PPID=99000\t;CLASS=shell\n' \
          "$i" "$(_b64 "$cwd")" "$(_b64 "$key-pane-$i")" "$(_b64 '/bin/zsh')" "$i"
      fi
    done
    printf 'sid\t1\t;CLAUDE_SID=%s\t;ROLE=primary\t;PID=99001\t;CLASS=claude\n' "$sid"
    printf 'end\t1\n'
  } > "$NS_DIR/$key.state"
  printf 'FROZEN %s — legacy banner\n' "$key" > "$NS_DIR/$key.banner"
}

KEY_W="1700000000-a97bff"
KEY_K="1700000001-b7c3d9"
SID_W="dddddddd-4444-4444-8444-dddddddddddd"
SID_K="eeeeeeee-5555-4555-8555-eeeeeeeeeeee"

_write_legacy_entry "$KEY_W" work:1 oldwin "$SID_W" "$C1" "$C2" "$C3"
_write_legacy_entry "$KEY_K" work:2 oldkey "$SID_K" "$K1" "$K2"

# Stage the windows exactly as the OLD model left them: ONE tombstone pane
# carrying the ❄ title, and the claim on the WINDOW option.
TOMB_W="$(_pane_id_at work:1 1)"
TOMB_K="$(_pane_id_at work:2 1)"
_t select-pane -t "$TOMB_W" -T "$(printf '%s FROZEN %s 3p/1s %s' "$SNOW" "$KEY_W" "$DAY")"
_t select-pane -t "$TOMB_K" -T "$(printf '%s FROZEN %s 2p/1s %s' "$SNOW" "$KEY_K" "$DAY")"
_t set-option -w -t work:1 @cc-frozen "$KEY_W"
_t set-option -w -t work:2 @cc-frozen "$KEY_K"
_t set-option -p -t "$TOMB_W" allow-rename off
_t set-option -p -t "$TOMB_K" allow-rename off

# ── [0] PREMISE ──────────────────────────────────────────────────────────────
echo "[0] PREMISE: two a97bff0 WINDOW-keyed entries, claimed the old way"
assert_eq "the legacy entry has no unit line (it predates the pane atom)" \
  "$(_scalar "$NS_DIR/$KEY_W.state" unit)" ""
assert_eq "its pane_count describes a WINDOW's panes, not one pane" \
  "$(_scalar "$NS_DIR/$KEY_W.state" pane_count)" "3"
assert_ne "it carries the layout the old model replayed" \
  "$(_scalar "$NS_DIR/$KEY_W.state" layout)" ""
assert_eq "the claim is on the WINDOW option, as the old model set it" \
  "$(_win_claim work:1)" "$KEY_W"
assert_eq "no pane carries the new per-pane claim" "$(_pane_claim "$TOMB_W")" ""
assert_eq "the window is collapsed to one tombstone pane" "$(_pane_count work:1)" "1"
assert_has "that pane wears the ❄ title" "$(_titles_of work:1)" "$SNOW FROZEN $KEY_W"
if [ "$fail" -ne 0 ]; then
  echo ""; echo "  Results: $pass passed, $fail failed (premise not established)"; exit 1
fi

# ── [1] The inventory must SEE it ────────────────────────────────────────────
# A legacy entry that no longer appears anywhere strands the user's session ids
# just as thoroughly as one that cannot be thawed.
echo ""
echo "[1] The tree inventory reports the legacy entries"
LIST="$(_list 2>"$TD/e1")"; RC=$?
printf '%s\n' "$LIST" | sed 's/^/    /'
assert_eq "--list exits 0" "$RC" "0"
ROW_W="$(printf '%s\n' "$LIST" | awk -F'\t' -v k="$KEY_W" '$11=="pane" && $9==k { print; exit }')"
ROW_K="$(printf '%s\n' "$LIST" | awk -F'\t' -v k="$KEY_K" '$11=="pane" && $9==k { print; exit }')"
if [ -n "$ROW_W" ]; then ok "the window-keyed entry appears as a row carrying its key"
else no "the window-keyed entry appears as a row carrying its key" "no row with key $KEY_W"; fi
if [ -n "$ROW_K" ]; then ok "the second legacy entry appears too"
else no "the second legacy entry appears too" "no row with key $KEY_K"; fi
assert_ne "the legacy row is not reported AWAKE" "$(_col "$ROW_W" 1)" "AWAKE"
assert_eq "its window row is reported non-awake as well" \
  "$(printf '%s\n' "$LIST" | awk -F'\t' -v k="$KEY_W" '$11=="window" && $9==k { print $1; exit }')" "FROZEN"
assert_eq "no field of the legacy row is empty (FR6.2: an empty TAB field vanishes)" \
  "$(printf '%s\n' "$ROW_W" | awk -F'\t' '{ n=0; for (i=1;i<=NF;i++) if ($i=="") n++ } END { print n+0 }')" "0"
assert_eq "the legacy row still has all 18 columns" \
  "$(printf '%s\n' "$ROW_W" | awk -F'\t' '{print NF; exit}')" "18"
assert_eq "the awake window is untouched by the presence of legacy entries" \
  "$(printf '%s\n' "$LIST" | awk -F'\t' '$11=="window" && $4=="awake" { print $1; exit }')" "AWAKE"

# ── [2] Thaw by session:index ────────────────────────────────────────────────
echo ""
echo "[2] Thaw the legacy WINDOW entry by session:index"
rm -f "$QD"/*
OUT="$(_thaw thaw --no-save work:1 2>"$TD/e2")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
[ -s "$TD/e2" ] && printf '    stderr: %s\n' "$(head -3 "$TD/e2")"
assert_eq "exit code 0"          "$RC" "0"
assert_eq "the verb is THAWED"   "$(_col "$OUT" 1)" "THAWED"
assert_eq "it reports the legacy key" "$(_col "$OUT" 3)" "$KEY_W"
assert_eq "it reports the 3 panes the entry described" "$(_col "$OUT" 4)" "3"
assert_eq "it reports the one resume it queued"        "$(_col "$OUT" 5)" "1"

assert_eq "the window is rebuilt to the recorded pane count" "$(_pane_count work:1)" "3"
BADCWD=0; BADTITLE=0; i=0
for want_cwd in "$C1" "$C2" "$C3"; do
  i=$((i+1))
  pid="$(_pane_id_at work:1 "$i")"
  if [ -z "$pid" ]; then BADCWD=$((BADCWD+1)); BADTITLE=$((BADTITLE+1)); continue; fi
  got_cwd="$(_t display-message -p -t "$pid" '#{pane_current_path}')"
  got_title="$(_t display-message -p -t "$pid" '#{pane_title}')"
  [ "$got_cwd" = "$want_cwd" ] || { BADCWD=$((BADCWD+1))
    echo "        pane $i cwd: got [$got_cwd] want [$want_cwd]"; }
  [ "$got_title" = "$KEY_W-pane-$i" ] || { BADTITLE=$((BADTITLE+1))
    echo "        pane $i title: got [$got_title] want [$KEY_W-pane-$i]"; }
done
assert_eq "every pane came back in its recorded cwd"   "$BADCWD" "0"
assert_eq "every pane came back with its recorded title" "$BADTITLE" "0"
assert_hasnt "no pane is left wearing a tombstone title" "$(_titles_of work:1)" "$SNOW FROZEN"
assert_eq "the legacy WINDOW claim is cleared" "$(_win_claim work:1)" ""

# the resume: keyed by a live pane id of THIS window, carrying the recorded sid
assert_eq "exactly one resume was queued" "$(_pending_count)" "1"
PF="$(_pending_files | head -1)"
assert_eq "the pending file is keyed by a CURRENT pane id of the window" \
  "$(_t list-panes -t work:1 -F '#{pane_id}' | sed 's/^%//' | grep -cx "${PF##*/}" | tr -d ' ')" "1"
assert_has "it resumes the session id the legacy entry recorded" \
  "$(cat "$PF" 2>/dev/null)" "--resume $SID_W"

# §3.2.9: the entry is retained and stamped, never deleted at thaw time
assert_ne "the legacy entry is retained, stamped thawed_at" \
  "$(_scalar "$NS_DIR/$KEY_W.state" thawed_at)" ""
assert_eq "its recorded sid is untouched" \
  "$(awk -F'\t' '$1=="sid"' "$NS_DIR/$KEY_W.state" | grep -c "$SID_W" | tr -d ' ')" "1"

# nothing else moved
assert_eq "the second legacy window is still frozen" "$(_win_claim work:2)" "$KEY_K"
assert_eq "the second legacy window is still one pane" "$(_pane_count work:2)" "1"
assert_eq "the awake window still has its 2 panes"   "$(_pane_count work:3)" "2"

# ── [3] Thaw by <key> ────────────────────────────────────────────────────────
echo ""
echo "[3] Thaw the other legacy entry by its KEY (§3.2 target grammar)"
rm -f "$QD"/*
OUT="$(_thaw thaw --no-save "$KEY_K" 2>"$TD/e3")"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
[ -s "$TD/e3" ] && printf '    stderr: %s\n' "$(head -3 "$TD/e3")"
assert_eq "exit code 0"        "$RC" "0"
assert_eq "the verb is THAWED" "$(_col "$OUT" 1)" "THAWED"
assert_eq "it reports that key" "$(_col "$OUT" 3)" "$KEY_K"
assert_eq "the window is rebuilt to 2 panes" "$(_pane_count work:2)" "2"
BADCWD=0; i=0
for want_cwd in "$K1" "$K2"; do
  i=$((i+1)); pid="$(_pane_id_at work:2 "$i")"
  [ -n "$pid" ] || { BADCWD=$((BADCWD+1)); continue; }
  got="$(_t display-message -p -t "$pid" '#{pane_current_path}')"
  [ "$got" = "$want_cwd" ] || { BADCWD=$((BADCWD+1)); echo "        pane $i cwd: got [$got] want [$want_cwd]"; }
done
assert_eq "both panes came back in their recorded cwds" "$BADCWD" "0"
assert_eq "the WINDOW claim is cleared"       "$(_win_claim work:2)" ""
assert_has "its recorded session id is queued" "$(cat $(_pending_files) 2>/dev/null)" "--resume $SID_K"

# ── [4] Idempotency after a legacy thaw ──────────────────────────────────────
echo ""
echo "[4] Thawing a legacy entry twice is a no-op that succeeds (FR2.5, AC10)"
PENDING_BEFORE="$(_pending_count)"
PANES_BEFORE="$(_pane_count work:1)"
OUT="$(_thaw thaw --no-save work:1 2>/dev/null)"; RC=$?
printf '    exit=%s stdout=[%s]\n' "$RC" "$OUT"
assert_eq "exit code 0"                "$RC" "0"
assert_eq "the verb is NOTFROZEN"      "$(_col "$OUT" 1)" "NOTFROZEN"
assert_eq "the pane count is unchanged" "$(_pane_count work:1)" "$PANES_BEFORE"
assert_eq "no extra resume was queued"  "$(_pending_count)" "$PENDING_BEFORE"

# ── [5] The inventory after the migration ────────────────────────────────────
echo ""
echo "[5] After thawing, no window is still reported frozen"
LIST="$(_list 2>/dev/null)"
printf '%s\n' "$LIST" | sed 's/^/    /'
assert_eq "no LIVE window row is still FROZEN or PARTIAL" \
  "$(printf '%s\n' "$LIST" | awk -F'\t' '$11=="window" && $13 ~ /^@[0-9]/ && $1!="AWAKE"' \
     | grep -c . | tr -d ' ')" "0"
assert_eq "every live window is reported AWAKE" \
  "$(printf '%s\n' "$LIST" | awk -F'\t' '$11=="window" && $13 ~ /^@[0-9]/ && $1=="AWAKE"' \
     | grep -c . | tr -d ' ')" "3"

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
