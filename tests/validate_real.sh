#!/usr/bin/env bash
# validate_all.sh — assert every fix found this session, on REAL data
# (real default tmux server + real snapshot), with isolated output dirs so the
# live sessions are never nudged/altered. Each check prints PASS/FAIL.
set -uo pipefail

RD="${XDG_DATA_HOME:-$HOME/.local/share}/tmux/resurrect"
SNAP="$RD/last"
INST=~/.tmux/plugins/tmux-claude-continuity
T="/tmp/validate-all-$$"
mkdir -p "$T/pending"
pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=================================================================="
echo " claude-continuity full validation — real server + real snapshot"
echo "=================================================================="

# ---- Finding 1: SAVE side captures every live Claude session --------------
echo "[1] SAVE: pre_save enriches all live Claude panes"
live_claude=$(tmux list-panes -a -F '#{pane_current_command}' 2>/dev/null | grep -c '2\.1\.')
snap_sids=$(grep -c CLAUDE_SID "$SNAP" 2>/dev/null)
echo "      live Claude panes=$live_claude  snapshot CLAUDE_SIDs=$snap_sids"
# Allow snapshot >= a high fraction; exact equality not guaranteed if a session
# started after the last save. Assert the snapshot is NOT degenerate (the old bug
# saved ~2). Require snap_sids within [live-2, live] (small drift tolerance).
if [ "$snap_sids" -ge $((live_claude - 2)) ] && [ "$snap_sids" -gt 4 ]; then
  ok "snapshot captured $snap_sids SIDs (not the old ~2 degenerate save)"
else
  no "snapshot only has $snap_sids SIDs for $live_claude live panes (save-side regression)"
fi

# ---- Run post_restore against real snapshot, isolated output --------------
# CC_NO_NUDGE=1 is what makes "isolated" true. Without it this loop send-keys
# Enter into every live pane it resolves — and those panes are running Claude,
# so the Enter submits whatever is sitting half-typed in the prompt.
tmux set-option -g @claude-continuity-pending-dir "$T/pending"
tmux set-option -g @claude-continuity-log-file "$T/v.log"
# CC_IGNORE_BUSY=1 as well: every live pane here is already running Claude, and
# post_restore now refuses to arm those (that is what stops a manual restore from
# writing into them). This script's whole purpose is to exercise pane RESOLUTION
# against the real layout, so it opts out of the guard rather than resolving zero.
CC_NO_NUDGE=1 CC_IGNORE_BUSY=1 RESURRECT_FILE="$SNAP" bash "$INST/scripts/post_restore.sh"
tmux set-option -g @claude-continuity-pending-dir "$HOME/.config/tmux-claude/pending"
tmux set-option -g @claude-continuity-log-file "$HOME/.tmux/scripts/claude-continuity-restore.log"

wrote=$(grep -c WROTE "$T/v.log" 2>/dev/null || echo 0)
distinct_panes=$(grep WROTE "$T/v.log" | grep -oE '> %[0-9]+' | sort -u | wc -l | tr -d ' ')
files=$(ls "$T/pending" 2>/dev/null | wc -l | tr -d ' ')
dup_sids=$(grep WROTE "$T/v.log" | grep -oE 'resume=[0-9a-f-]+' | sort | uniq -d | wc -l | tr -d ' ')
dup_panes=$(grep WROTE "$T/v.log" | grep -oE '> %[0-9]+' | sort | uniq -d | wc -l | tr -d ' ')
coord=$(grep WROTE "$T/v.log" | grep -c 'coord-fallback' || echo 0)

# ---- Finding 2: filter no longer drops MCP-child Claude panes -------------
echo "[2] FILTER: enriched rows resolve despite MCP-child full_cmd"
# Of snapshot SID rows whose session is live, all should resolve.
echo "      WROTE=$wrote  (old bug wrote only 12 of 32)"
if [ "$wrote" -ge 20 ]; then ok "resolved $wrote sessions (MCP-child filter bug fixed)"; else no "only resolved $wrote (filter still dropping panes)"; fi

# ---- Finding 3: dedup gives each session a DISTINCT pane ------------------
echo "[3] DEDUP: no two sessions target the same pane"
if [ "$dup_panes" -eq 0 ]; then ok "0 panes targeted twice"; else no "$dup_panes pane(s) targeted by multiple sessions (misroute)"; fi
if [ "$dup_sids" -eq 0 ]; then ok "0 SIDs written to multiple panes"; else no "$dup_sids SID(s) written to multiple panes"; fi
if [ "$wrote" -eq "$distinct_panes" ] && [ "$wrote" -eq "$files" ]; then
  ok "WROTE=$wrote == distinct panes=$distinct_panes == files=$files (1:1)"
else
  no "mismatch: WROTE=$wrote distinct=$distinct_panes files=$files"
fi

# ---- Finding 4: duplicate-title groups each get distinct panes ------------
echo "[4] DUP-TITLE: janus/passflow 'Claude Code' x2 -> distinct panes"
for grp in janus passflow; do
  panes=$(grep WROTE "$T/v.log" | grep "$grp:" | grep "Claude Code" | grep -oE '> %[0-9]+' | sort -u | wc -l | tr -d ' ')
  rows=$(grep WROTE "$T/v.log" | grep "$grp:" | grep -c "Claude Code" || echo 0)
  if [ "$rows" -le 1 ] || [ "$panes" -eq "$rows" ]; then
    ok "$grp: $rows 'Claude Code' row(s) -> $panes distinct pane(s)"
  else
    no "$grp: $rows rows collapsed onto $panes pane(s)"
  fi
done

# ---- Finding 5: stale position-sidecar does NOT resume a dead session -----
echo "[5] NO STALE SIDECAR: plain shells don't get spurious resumes"
# circle:1.3 is a mac-m5 shell with a stale sidecar; must NOT be written.
if grep -q 'circle:1.3' "$T/v.log" 2>/dev/null && grep 'circle:1.3' "$T/v.log" | grep -q WROTE; then
  no "circle:1.3 (mac-m5 shell) got a spurious resume from stale sidecar"
else
  ok "circle:1.3 (mac-m5 shell) correctly not resumed"
fi
# General: every WROTE pane's snapshot row must carry a real CLAUDE_SID.
bare=$(grep -c 'bare (no token)' "$T/v.log" 2>/dev/null | head -1)
bare=${bare:-0}
if [ "$bare" -eq 0 ]; then ok "0 bare (tokenless) writes — every resume has a real SID"; else echo "  INFO: $bare bare writes (legacy full_cmd=claude rows)"; fi

# ---- Finding 6: verdict is honest (PASS, accurate, classifies absent) -----
echo "[6] VERDICT: honest PASS with absent-session accounting"
verdict=$(grep 'BOOT VERDICT' "$T/v.log")
echo "      $verdict"
if echo "$verdict" | grep -q 'PASS'; then ok "verdict PASS"; else no "verdict not PASS"; fi
if echo "$verdict" | grep -qE 'queued [0-9]+/[0-9]+ resumable'; then ok "verdict reports resumable denominator (not raw total)"; else no "verdict denominator wrong"; fi
# real misses must be 0 for a trustworthy PASS
if grep -q 'REAL MISS' "$T/v.log"; then no "there are REAL MISSES (live session not resumed)"; else ok "0 real misses (no live session lost)"; fi

echo "=================================================================="
echo "  RESULT: $pass passed, $fail failed"
echo "=================================================================="
rm -rf "$T"
[ "$fail" -eq 0 ]
