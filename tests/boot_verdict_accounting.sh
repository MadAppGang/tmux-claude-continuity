#!/usr/bin/env bash
# boot_verdict_accounting.sh — the boot verdict must not be able to certify a
# boot that resumed nothing.
#
# WHAT WENT WRONG, on the live machine, in its own log:
#   BOOT VERDICT: PASS — queued 31/26 resumable session(s) (0 absent …, 26 total)
#   BOOT VERDICT: PASS — queued 0/-5 resumable session(s) (31 absent …, 26 total)
# The numerator counted rows the loop actually armed; the denominator was a
# separate awk counting rows that carried a CLAUDE_SID. Those are different
# populations — the loop also admits legacy un-enriched rows and configured
# restore_procs — so the numerator could exceed the denominator, and once the
# skip counters exceeded `total` the denominator went NEGATIVE. `0 >= -5` is
# true, so a run against an ALREADY-DEAD server printed PASS.
#
# This is the recurring bug class in this codebase: a gate whose passing
# condition is satisfiable by two zeros (or by a negative) proves nothing. Every
# assertion here is therefore paired with a check that the scenario was real.
set -u

CD="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$CD/../scripts"
# Overridable so the same assertions can be pointed at an older checkout to prove
# they actually detect the bug, rather than merely agreeing with today's code.
POST="${CC_POST_RESTORE:-$SCRIPTS/post_restore.sh}"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; [ $# -gt 1 ] && echo "        $2"; fail=$((fail+1)); }

SOCKET="ccbv$$"
case "$SOCKET" in default|"") echo "unsafe socket"; exit 1 ;; esac
TD="$(mktemp -d /tmp/ccbv-XXXXXX)"
_t() { tmux -L "$SOCKET" -f /dev/null "$@"; }
cleanup() { _t kill-server 2>/dev/null; rm -rf "$TD"; }
trap cleanup EXIT INT TERM

PD="$TD/panes"; LOG="$TD/v.log"
mkdir -p "$PD/by-pid" "$TD/pending"

_t new-session -d -s alive -x 80 -y 24
_t set-option -g @claude-continuity-panes-dir  "$PD"  >/dev/null
_t set-option -g @claude-continuity-pending-dir "$TD/pending" >/dev/null
_t set-option -g @claude-continuity-log-file    "$LOG" >/dev/null

_mkpane() { # <session> <win> <pane> <title> <cmd> [extra]
  printf 'pane\t%s\t%s\t1\t:*\t%s\t%s\t:%s\t1\tsh\t:%s%s\n' \
    "$1" "$2" "$3" "$4" "$TD" "$5" "${6:+	$6}"
}
_run() { # <snapshot> -> runs post_restore against it, returns the verdict line
  : > "$LOG"
  CC_NO_NUDGE=1 TMUX_CMD="tmux -L $SOCKET -f /dev/null" \
    RESURRECT_FILE="$1" bash "$POST" >/dev/null 2>&1
  grep 'BOOT VERDICT' "$LOG" 2>/dev/null | tail -1
}

echo "=================================================================="
echo " boot verdict accounting"
echo "=================================================================="

# ── 1. A snapshot whose sessions are ALL absent from the live layout ─────────
# This is the shape that produced "queued 0/-5 … PASS". Every row names a
# session that does not exist, so nothing can be armed.
S1="$TD/all-absent.txt"
{ _mkpane ghost 1 1 'Claude Code' 'claude --resume aaaa' ';CLAUDE_SID=11111111-1111-4111-8111-111111111111'
  _mkpane ghost 2 1 'Claude Code' 'claude --resume bbbb' ';CLAUDE_SID=22222222-2222-4222-8222-222222222222'
  _mkpane ghost 3 1 'Claude Code' 'claude --resume cccc'
  _mkpane ghost 4 1 'Claude Code' 'claude --resume dddd'
  printf 'state\tghost\tghost\n'
} > "$S1"
V1="$(_run "$S1")"
echo "    $V1"
case "$V1" in
  *PASS*) no "a boot that resumed NOTHING must not report PASS" "got: $V1" ;;
  *"NOTHING TO RESUME"*) ok "a boot that resumed nothing reports NOTHING TO RESUME, not PASS" ;;
  *INCOMPLETE*) ok "a boot that resumed nothing does not report PASS (reported INCOMPLETE)" ;;
  *) no "a verdict was produced at all" "got: [$V1]" ;;
esac
# non-vacuity: the scenario must really have had candidate rows to lose
case "$V1" in
  *"4 candidate row"*|*"absent"*) ok "the scenario really did present rows that could not be armed" ;;
  *) no "the scenario presented rows" "verdict names no candidates: $V1" ;;
esac

# ── 2. The denominator can never be negative, and the numerator can never
#       exceed it. This is the "31/26" shape: more rows qualify than carry a sid.
S2="$TD/mixed.txt"
{ _mkpane ghost 1 1 'Claude Code' 'claude --resume aaaa' ';CLAUDE_SID=33333333-3333-4333-8333-333333333333'
  _mkpane ghost 2 1 'Claude Code' 'claude --resume bbbb'
  _mkpane ghost 3 1 'Claude Code' 'claude --resume cccc'
  _mkpane ghost 4 1 'Claude Code' 'claude --resume dddd'
  _mkpane ghost 5 1 'Claude Code' 'claude --resume eeee'
  printf 'state\tghost\tghost\n'
} > "$S2"
V2="$(_run "$S2")"
echo "    $V2"
NUM="$(printf '%s' "$V2" | sed -n 's/.*queued \([0-9-]*\)\/.*/\1/p')"
DEN="$(printf '%s' "$V2" | sed -n 's/.*queued [0-9-]*\/\([0-9-]*\).*/\1/p')"
if [ -n "$DEN" ]; then
  [ "$DEN" -ge 0 ] && ok "denominator is not negative (got $DEN)" \
                   || no "denominator is not negative" "got $DEN in: $V2"
  [ "${NUM:-0}" -le "$DEN" ] && ok "numerator does not exceed denominator ($NUM/$DEN)" \
                             || no "numerator does not exceed denominator" "$NUM/$DEN in: $V2"
else
  # a NOTHING TO RESUME verdict carries no fraction, which is itself correct here
  case "$V2" in
    *"NOTHING TO RESUME"*) ok "no fraction printed because nothing was resumable (correct)"
                           ok "no negative denominator can appear when no fraction is printed" ;;
    *) no "a fraction or a NOTHING verdict was produced" "got: [$V2]" ;;
  esac
fi

# ── 3. ANTI-VACUITY: the verdict must still be able to say PASS. A gate that
#       can only ever refuse is as useless as one that can only ever accept.
#       Here the session IS live and the pane IS a shell, so the row can arm.
S3="$TD/resumable.txt"
{ _mkpane alive 0 0 'Claude Code' 'claude --resume ffff' ';CLAUDE_SID=44444444-4444-4444-8444-444444444444'
  printf 'state\talive\talive\n'
} > "$S3"
V3="$(_run "$S3")"
echo "    $V3"
case "$V3" in
  *PASS*) ok "a boot that DID arm a resumable row still reports PASS (gate is not vacuous)" ;;
  *) no "PASS is still reachable" "got: $V3 — if this cannot pass, the verdict is useless" ;;
esac

echo "=================================================================="
echo "  RESULT: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
