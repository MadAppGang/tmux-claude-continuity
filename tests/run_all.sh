#!/usr/bin/env bash
# run_all.sh — run every test, and refuse to keep going if one of them touches
# the machine's REAL state.
#
# WHY THIS EXISTS. On 2026-08-17 a full suite run ended with the user's default
# tmux server gone: 16 sessions, 44 windows and 71 panes destroyed. No crash
# report was written, no test contained an unscoped `kill-server`, and nothing in
# any log named a culprit — so the cause could not be pinned down after the fact.
# That is the actual failure: not that a test misbehaved, but that a suite of
# save/restore tests could damage the live system and finish GREEN, leaving no
# way to tell which one did it.
#
# This runner fingerprints the real world before and after EVERY test and stops
# the moment a fingerprint moves. It cannot prevent the damage, but it names the
# test that caused it and stops the remaining tests from adding to it — which is
# the difference between a five-minute fix and an afternoon of guessing.
#
# It checks two things a test must never disturb:
#   * the DEFAULT tmux server (its session list) — the user's real work.
#   * the real resurrect directory listing — the user's real snapshots. Counting
#     files is not enough there, because the directory rotates; the listing is
#     hashed instead.
set -u

CD="$(cd "$(dirname "$0")" && pwd)"
REAL_RESURRECT="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"

server_fp() {
  if tmux list-sessions >/dev/null 2>&1; then
    printf 'alive:%s' "$(tmux list-sessions -F '#{session_name}' 2>/dev/null | sort | tr '\n' ',')"
  else
    printf 'absent'
  fi
}
resurrect_fp() { ls -1 "$REAL_RESURRECT" 2>/dev/null | sort | shasum | awk '{print $1}'; }

SRV0="$(server_fp)"; RES0="$(resurrect_fp)"
echo "=================================================================="
echo " tmux-claude-continuity test suite"
echo "=================================================================="
printf ' guarding default server : %s\n' \
  "$(printf '%s' "$SRV0" | cut -c1-72)$([ "${#SRV0}" -gt 72 ] && printf '…')"
printf ' guarding resurrect dir  : %s (%s snapshots)\n' \
  "$RES0" "$(ls -1 "$REAL_RESURRECT"/tmux_resurrect_*.txt 2>/dev/null | wc -l | tr -d ' ')"
echo ""

TOTP=0; TOTF=0; RAN=0; BREACH=""
FAILING=""

# Tests that operate on the REAL default server rather than a private socket.
# validate_real.sh is deliberately one of these: its whole purpose is to exercise
# pane resolution against the live layout and the live snapshot, so it sets
# @claude-continuity-* options on the user's server and runs post_restore.sh
# there. That is legitimate as a hand-run diagnostic and NOT something a suite
# should do unattended — it is the only test that can alter live state, and a
# suite run on 2026-08-17 ended with the real server gone. It is therefore
# skipped unless explicitly opted into with CC_ALLOW_REAL=1.
REAL_STATE_TESTS="validate_real.sh"

for t in "$CD"/*.sh; do
  b="$(basename "$t")"
  case "$b" in run_all.sh|_*) continue ;; esac
  [ -f "$t" ] || continue
  case " $REAL_STATE_TESTS " in
    *" $b "*)
      if [ "${CC_ALLOW_REAL:-0}" != "1" ]; then
        printf '  %-30s SKIPPED (touches the live server; CC_ALLOW_REAL=1 to run)\n' "$b"
        continue
      fi
      printf '  %-30s running against LIVE state (CC_ALLOW_REAL=1)\n' "$b" ;;
  esac

  out="$(timeout 900 bash "$t" 2>&1)"
  # tests print either "RESULT: N passed, M failed" or "Results: N passed, M failed"
  line="$(printf '%s' "$out" | grep -iE '(RESULT|Results):[[:space:]]+[0-9]+ passed' | tail -1)"
  # Read the number that PRECEDES the words "passed"/"failed" rather than
  # anchoring on the label. The label is "RESULT:" in some files and "Results:"
  # in others, and a case-sensitive sed silently produced an empty count for the
  # all-caps ones — which then added 0 to the totals and reported a suite of 788
  # when it was really 813. A parser that fails quietly is worse than one that
  # errors: the number still looked plausible.
  p="$(printf '%s' "$line" | awk '{for(i=2;i<=NF;i++) if($i ~ /^passed/) {print $(i-1); exit}}')"
  f="$(printf '%s' "$line" | awk '{for(i=2;i<=NF;i++) if($i ~ /^failed/) {print $(i-1); exit}}')"
  RAN=$((RAN + 1))

  if [ -z "$line" ]; then
    printf '  %-30s NO RESULT LINE\n' "$b"
    FAILING="$FAILING $b(noresult)"
  else
    if [ "${f:-0}" -gt 0 ]; then
      printf '  %-30s %3s passed, %3s FAILED\n' "$b" "${p:-?}" "${f:-?}"
      FAILING="$FAILING $b($f)"
    else
      printf '  %-30s %3s passed\n' "$b" "${p:-?}"
    fi
    TOTP=$((TOTP + ${p:-0})); TOTF=$((TOTF + ${f:-0}))
  fi

  # ── the part that matters ──────────────────────────────────────────────────
  SRV1="$(server_fp)"; RES1="$(resurrect_fp)"
  if [ "$SRV1" != "$SRV0" ]; then
    BREACH="$b changed the DEFAULT TMUX SERVER"
    echo ""
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  !!! $b DISTURBED THE REAL TMUX SERVER"
    echo "  !!!   before: $SRV0"
    echo "  !!!   after : $SRV1"
    echo "  !!! Stopping so the remaining tests cannot do more damage."
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    break
  fi
  if [ "$RES1" != "$RES0" ]; then
    BREACH="$b wrote into the real resurrect directory"
    echo ""
    echo "  !!! $b CHANGED $REAL_RESURRECT"
    echo "  !!! Stopping. Inspect the newest files there before rerunning."
    break
  fi
done

echo ""
echo "=================================================================="
printf '  %s test file(s): %s passed, %s failed\n' "$RAN" "$TOTP" "$TOTF"
[ -n "$FAILING" ] && printf '  failing:%s\n' "$FAILING"
if [ -n "$BREACH" ]; then
  printf '  REAL-STATE BREACH: %s\n' "$BREACH"
  echo "=================================================================="
  exit 2
fi
echo "  real tmux server and resurrect directory: UNTOUCHED"
echo "=================================================================="
[ "$TOTF" -eq 0 ] && [ -z "$FAILING" ]
