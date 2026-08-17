#!/usr/bin/env bash
# relaunch_flag_accumulation.sh — the relaunch command must not grow a copy of
# the launcher's own flags on every restore.
#
# MEASURED, on the live machine, before the fix: 21 running Claude processes
# carried `--dangerously-skip-permissions` FOUR times, and 19 snapshot rows
# recorded it four times. The plain-claude path composes `$base_cmd $args`,
# where base_cmd is the configured launcher (which supplies the flag) and args
# come from the snapshot row (which was itself written by the PREVIOUS relaunch,
# and so supplies it too). Each restore adds one more copy, and each save
# records the result, so it compounds without bound.
#
# The interesting half of this test is the second half: the fix must NOT touch a
# flag that takes a VALUE, because such flags are legitimately repeatable and
# dropping one occurrence would discard its value and shift the following token
# into a flag position.
set -u

CD="$(cd "$(dirname "$0")" && pwd)"
LIB="$CD/../scripts/lib"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; [ $# -gt 1 ] && echo "        $2"; fail=$((fail+1)); }

# shellcheck source=/dev/null
. "$LIB/cc_common.sh"   2>/dev/null
. "$LIB/cc_proc.sh"     2>/dev/null
. "$LIB/cc_relaunch.sh" 2>/dev/null

if ! type cc_compose_relaunch_kv >/dev/null 2>&1; then
  echo "  RESULT: 0 passed, 1 failed (cc_relaunch.sh not loadable)"; exit 1
fi

BASE="claude --dangerously-skip-permissions"
SID="12345678-1234-4234-8234-123456789abc"

compose() { # <full_cmd> -> the composed relaunch command
  cc_compose_relaunch "$BASE" "claudish" "" "$1" "" "$SID"
}
count_flag() { printf '%s' "$1" | grep -o -- '--dangerously-skip-permissions' | grep -c .; }

echo "=================================================================="
echo " relaunch flag accumulation"
echo "=================================================================="

# ── 1. one cycle: the row already carries the flag the launcher supplies ─────
R1="$(compose "claude --dangerously-skip-permissions --resume OLDSID")"
echo "    $R1"
n1="$(count_flag "$R1")"
[ "$n1" -eq 1 ] && ok "flag appears exactly once after one cycle (got $n1)" \
                || no "flag appears exactly once after one cycle" "got $n1 in: $R1"

# ── 2. a row that already accumulated four copies must collapse back to one ──
R2="$(compose "claude --dangerously-skip-permissions --dangerously-skip-permissions --dangerously-skip-permissions --dangerously-skip-permissions --resume OLDSID")"
echo "    $R2"
n2="$(count_flag "$R2")"
[ "$n2" -eq 1 ] && ok "an already-quadrupled row collapses back to one (got $n2)" \
                || no "an already-quadrupled row collapses to one" "got $n2 in: $R2"

# ── 3. ITERATED: feed each cycle's output back in, as a real restore does.
#       This is the property that actually matters — one pass looking right
#       proves nothing about a loop that runs on every reboot.
cur="claude --dangerously-skip-permissions --resume OLDSID"
i=0
while [ "$i" -lt 6 ]; do
  cur="$(compose "$cur")"
  i=$((i + 1))
done
echo "    after 6 cycles: $cur"
n3="$(count_flag "$cur")"
[ "$n3" -eq 1 ] && ok "still exactly one flag after SIX restore cycles (got $n3)" \
                || no "still one flag after six cycles" "got $n3 — it is still compounding: $cur"

# ── 4. the pane's OWN arguments must survive ────────────────────────────────
R4="$(compose "claude --dangerously-skip-permissions --worktree logs-fix --resume OLDSID")"
echo "    $R4"
case "$R4" in
  *"--worktree logs-fix"*) ok "the pane's own --worktree argument is preserved" ;;
  *) no "the pane's own arguments are preserved" "lost --worktree in: $R4" ;;
esac

# ── 5. ANTI-OVERREACH: a flag that TAKES A VALUE must never be dropped, even
#       when the same flag name appears in the base command. Dropping it would
#       discard the value and shift the next token into a flag position.
BASE_WITH_VALUE="claude --model opus"
R5="$(cc_compose_relaunch "$BASE_WITH_VALUE" "claudish" "" "claude --model sonnet --resume OLDSID" "" "$SID")"
echo "    $R5"
case "$R5" in
  *"--model sonnet"*) ok "a value-taking flag keeps its value (--model sonnet survives)" ;;
  *) no "a value-taking flag keeps its value" "lost '--model sonnet' in: $R5" ;;
esac

# ── 6. and a repeatable value flag keeps BOTH values ────────────────────────
R6="$(cc_compose_relaunch "claude --add-dir /a" "claudish" "" "claude --add-dir /a --add-dir /b --resume OLDSID" "" "$SID")"
echo "    $R6"
if printf '%s' "$R6" | grep -q -- '--add-dir /a' && printf '%s' "$R6" | grep -q -- '--add-dir /b'; then
  ok "a repeatable value flag keeps both of its values"
else
  no "a repeatable value flag keeps both values" "got: $R6"
fi

# ── 7. the resume token is still appended, once ─────────────────────────────
c7="$(printf '%s' "$R1" | grep -o -- '--resume' | grep -c .)"
[ "$c7" -eq 1 ] && ok "exactly one --resume in the composed command" \
                || no "exactly one --resume" "got $c7 in: $R1"
case "$R1" in *"--resume $SID"*) ok "it resumes the NEW sid, not the snapshot's old one" ;;
              *) no "resumes the new sid" "got: $R1" ;; esac

echo "=================================================================="
echo "  RESULT: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
