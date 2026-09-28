#!/usr/bin/env bash
# launch_verdict.sh — the post-launch check must see a relaunch that failed.
#
# WHAT WENT WRONG, on the live machine, on 2026-09-26:
#   BOOT VERDICT: PASS — queued 38/38 resumable session(s)
# while four panes launched through `wt` had printed wt's usage text and dropped
# back to a bare prompt. The boot verdict certifies what was QUEUED; nothing
# looked at what came back. verify_launch.sh does, and this test drives it
# against one pane of every shape it must tell apart, plus an all-good run to
# prove the gate can still say PASS.
#
# Everything runs on a private socket with -f /dev/null and /bin/sh panes: a zsh
# pane would source the real continuity hook and act on the real pending dir.
set -u

CD="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$CD/../scripts"
VERIFY="$SCRIPTS/verify_launch.sh"
POST="$SCRIPTS/post_restore.sh"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; [ $# -gt 1 ] && echo "        $2"; fail=$((fail+1)); }

SOCKET="cclv$$"
case "$SOCKET" in default|"") echo "unsafe socket"; exit 1 ;; esac
TD="$(mktemp -d /tmp/cclv-XXXXXX)"
TCMD="tmux -L $SOCKET -f /dev/null"
_t() { $TCMD "$@"; }
cleanup() { _t kill-server 2>/dev/null; rm -rf "$TD"; }
trap cleanup EXIT INT TERM

PD="$TD/panes"; LOG="$TD/v.log"; PEND="$TD/pending"
mkdir -p "$PD/by-pid" "$PEND" "$TD/bin"

# A stand-in claude: a shell script that stays alive, so ps shows
# `/bin/sh …/bin/claude --resume <sid>` and the exec token resolves to claude.
cat > "$TD/bin/claude" <<'EOF'
#!/bin/sh
while :; do sleep 5; done
EOF
chmod +x "$TD/bin/claude"

_t new-session -d -s lv -x 120 -y 30 -c "$TD" "sh -c 'while :; do sleep 5; done'"
_t set-option -g default-shell /bin/sh >/dev/null
_t set-option -g @claude-continuity-panes-dir  "$PD"   >/dev/null
_t set-option -g @claude-continuity-pending-dir "$PEND" >/dev/null
_t set-option -g @claude-continuity-log-file    "$LOG"  >/dev/null

_win() { _t new-window -d -P -F '#{pane_id}' -t lv -c "$TD" "$1"; }

S_OK=11111111-1111-4111-8111-111111111111
S_OTHER=22222222-2222-4222-8222-222222222222
S_WANT=33333333-3333-4333-8333-333333333333

p_ok="$(_win "$TD/bin/claude --resume $S_OK")"
p_exit="$(_win "sh -c 'echo \"usage: wt <name> [colour]\"; exec sh'")"
p_nf="$(_win "sh")"; : > "$PEND/${p_nf#%}"
p_stall="$(_win "sleep 600")"
p_proc="$(_win "sleep 600")"
p_other="$(_win "$TD/bin/claude --resume $S_OTHER")"
p_gone="%99999"
sleep 1

_verify() { # <manifest>
  : > "$LOG"
  _t set-option -gu @claude-continuity-boot-warning 2>/dev/null
  CC_VERIFY_WAIT=4 CC_VERIFY_SETTLE=0 CC_VERIFY_POLL=1 TMUX_CMD="$TCMD" \
    bash "$VERIFY" "$1" >/dev/null 2>&1
}

echo "=================================================================="
echo " launch verdict"
echo "=================================================================="

# ── 1. One pane of every shape ───────────────────────────────────────────────
M1="$TD/m1.tsv"
printf '%s\tlv:1.0\tclaude\t%s\tok\n'       "$p_ok"    "$S_OK"    >  "$M1"
printf '%s\tlv:2.0\tclaude\t%s\texit\n'     "$p_exit"  "$S_OK"    >> "$M1"
printf '%s\tlv:3.0\tclaude\t%s\tnotfired\n' "$p_nf"    "$S_OK"    >> "$M1"
printf '%s\tlv:4.0\tclaude\t%s\tstall\n'    "$p_stall" "$S_OK"    >> "$M1"
printf '%s\tlv:5.0\tproc\t-\tproc\n'        "$p_proc"             >> "$M1"
printf '%s\tlv:6.0\tclaude\t%s\tother\n'    "$p_other" "$S_WANT"  >> "$M1"
printf '%s\tlv:7.0\tclaude\t%s\tgone\n'     "$p_gone"  "$S_OK"    >> "$M1"
_verify "$M1"
V1="$(grep 'LAUNCH VERDICT' "$LOG" | tail -1)"
echo "    $V1"

grep -q "LAUNCH OK lv:1.0 .*resumed $S_OK" "$LOG" \
  && ok "claude running on the saved sid is OK and says so" \
  || no "claude running on the saved sid is OK" "$(grep 'lv:1.0' "$LOG")"
grep -q "LAUNCH EXITED lv:2.0" "$LOG" \
  && ok "a pane back at a shell after the relaunch is EXITED" \
  || no "a pane back at a shell is EXITED" "$(grep 'lv:2.0' "$LOG")"
grep -q '| usage: wt <name> \[colour\]' "$LOG" \
  && ok "the EXITED pane's last lines (the reason it failed) are in the log" \
  || no "the EXITED pane's output is in the log" "$(cat "$LOG")"
grep -q "LAUNCH NOT-FIRED lv:3.0" "$LOG" \
  && ok "an unconsumed pending file is NOT-FIRED" \
  || no "an unconsumed pending file is NOT-FIRED" "$(grep 'lv:3.0' "$LOG")"
grep -q "LAUNCH STALLED lv:4.0" "$LOG" \
  && ok "a Claude row whose pane runs something else is STALLED" \
  || no "a Claude row running something else is STALLED" "$(grep 'lv:4.0' "$LOG")"
grep -q "LAUNCH OK lv:5.0 .*running 'sleep'" "$LOG" \
  && ok "a non-Claude row running its program is OK" \
  || no "a non-Claude row running its program is OK" "$(grep 'lv:5.0' "$LOG")"
grep -q "LAUNCH OK lv:6.0 .*not on $S_WANT" "$LOG" \
  && ok "claude on a different session is OK but flagged" \
  || no "claude on a different session is flagged" "$(grep 'lv:6.0' "$LOG")"
grep -q "LAUNCH GONE lv:7.0" "$LOG" \
  && ok "a pane that no longer exists is GONE" \
  || no "a missing pane is GONE" "$(grep 'lv:7.0' "$LOG")"
case "$V1" in
  *"FAIL — 4/7 armed pane(s) did not come back (1 exited, 1 never fired, 1 stalled, 1 gone), 1 running a session other"*)
    ok "the verdict is FAIL with every failure counted" ;;
  *) no "the verdict is FAIL with every failure counted" "got: [$V1]" ;;
esac
W1="$(_t show-option -gqv @claude-continuity-boot-warning 2>/dev/null)"
case "$W1" in
  *"4/7 relaunch(es) failed"*) ok "a FAIL raises the status-line warning" ;;
  *) no "a FAIL raises the status-line warning" "got: [$W1]" ;;
esac
[ ! -e "$M1" ] && ok "the manifest is removed when the run ends" \
               || no "the manifest is removed when the run ends"

# ── 2. ANTI-VACUITY: all good must say PASS and raise nothing ────────────────
M2="$TD/m2.tsv"
printf '%s\tlv:1.0\tclaude\t%s\tok\n' "$p_ok"   "$S_OK" >  "$M2"
printf '%s\tlv:5.0\tproc\t-\tproc\n'  "$p_proc"         >> "$M2"
_verify "$M2"
V2="$(grep 'LAUNCH VERDICT' "$LOG" | tail -1)"
echo "    $V2"
case "$V2" in
  *"PASS — 2/2 armed pane(s) came back") ok "a run where everything came back is PASS" ;;
  *) no "a run where everything came back is PASS" "got: [$V2]" ;;
esac
W2="$(_t show-option -gqv @claude-continuity-boot-warning 2>/dev/null)"
[ -z "$W2" ] && ok "a PASS raises no warning" || no "a PASS raises no warning" "got: [$W2]"

# ── 3. post_restore arms the check itself ────────────────────────────────────
# A resumable row resolving to a bare /bin/sh pane: post_restore writes the
# pending file, but no precmd hook exists in sh to consume it — exactly the
# "queued, never ran" shape. The boot verdict must still say PASS (it was
# queued), and the launch verdict that post_restore spawns must say FAIL.
_t new-session -d -s pr -x 120 -y 30 -c "$TD" "sh"
_t set-option -gu @claude-continuity-boot-warning 2>/dev/null
SNAP="$TD/snap.txt"
printf 'pane\tpr\t0\t1\t:*\t0\tClaude Code\t:%s\t1\tsh\t:claude\t;CLAUDE_SID=%s\n' "$TD" "$S_OK" > "$SNAP"
printf 'state\tpr\tpr\n' >> "$SNAP"
: > "$LOG"
CC_VERIFY_WAIT=3 CC_VERIFY_SETTLE=0 CC_VERIFY_POLL=1 TMUX_CMD="$TCMD" \
  RESURRECT_FILE="$SNAP" bash "$POST" >/dev/null 2>&1
grep -q 'BOOT VERDICT: PASS' "$LOG" \
  && ok "post_restore queued the row (boot verdict PASS — the blind spot)" \
  || no "post_restore queued the row" "$(grep 'VERDICT\|WROTE\|SKIP' "$LOG")"
grep -q 'launch verify: watching 1 armed pane' "$LOG" \
  && ok "post_restore spawned the launch check for the pane it armed" \
  || no "post_restore spawned the launch check" "$(tail -5 "$LOG")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  grep -q 'LAUNCH VERDICT' "$LOG" && break
  sleep 1
done
V3="$(grep 'LAUNCH VERDICT' "$LOG" | tail -1)"
echo "    $V3"
case "$V3" in
  *"FAIL — 1/1"*"1 never fired"*) ok "the detached check reports the queued-but-never-ran pane as FAIL" ;;
  *) no "the detached check reports FAIL" "got: [$V3]" ;;
esac

# ── 4. A diagnostic run (CC_NO_NUDGE) launches nothing and verifies nothing ──
: > "$LOG"; rm -f "$PEND"/*
CC_NO_NUDGE=1 TMUX_CMD="$TCMD" RESURRECT_FILE="$SNAP" bash "$POST" >/dev/null 2>&1
grep -q 'launch verify' "$LOG" \
  && no "CC_NO_NUDGE does not spawn a launch check" "$(grep 'launch verify' "$LOG")" \
  || ok "CC_NO_NUDGE does not spawn a launch check"

echo
echo "  RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
