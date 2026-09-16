#!/usr/bin/env bash
# tab_colour_hook_wiring.sh — do the producers actually call the one consumer?
#
# The tab is painted by an event-driven design whose named weakness is that NO
# SINGLE PLACE shows what paints a tab: three hooks and a key binding all feed
# one script. The mitigation is that they all call the SAME script, so the
# catalogue of producers is `grep -rl cc_tab_reconcile` — and this file is what
# keeps that grep honest.
#
# ── WHY THERE IS NO TMUX SERVER HERE ─────────────────────────────────────────
# The Claude hooks call the reconciler with NO TMUX_CMD override, because in
# production it must talk to the user's default server. Running them for real
# would therefore point the reconciler at the LIVE tmux server. So `tmux` is
# shimmed onto PATH (the tests/pre_restore_launch_purge.sh pattern) and the
# reconciler itself is replaced by a stub that records its argv: this file
# tests the WIRING, and tab_colour_ownership.sh tests the behaviour against an
# isolated server. Nothing here starts or contacts a tmux server of any kind.
#
# Usage: bash tests/tab_colour_hook_wiring.sh   (exit 0 = pass)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

TD="$(mktemp -d /tmp/cctabhook-XXXXXX)" || exit 1
trap 'rm -rf "$TD"' EXIT INT TERM HUP

mkdir -p "$TD/bin" "$TD/scripts" "$TD/panes" || exit 1

# ── The tmux shim ────────────────────────────────────────────────────────────
# Answers only what the two hooks ask, and never contacts a server.
cat > "$TD/bin/tmux" <<EOF
#!/bin/sh
case "\$1 \$3" in
  "show-option @claude-continuity-panes-dir") printf '%s\n' "$TD/panes"; exit 0 ;;
esac
[ "\$1" = "display-message" ] && { printf 'sess-1-1\n'; exit 0; }
exit 0
EOF
chmod +x "$TD/bin/tmux"

# ── The reconciler stub ──────────────────────────────────────────────────────
# Resolved by the hooks as "$(dirname "$0")/cc_tab_reconcile.sh", so copying the
# hooks next to it exercises the real path resolution.
CALLS="$TD/calls"
cat > "$TD/scripts/cc_tab_reconcile.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$CALLS"
exit 0
EOF
chmod +x "$TD/scripts/cc_tab_reconcile.sh"

cp "$ROOT/scripts/on_stop.sh" "$TD/scripts/on_stop.sh"
cp "$ROOT/scripts/on_session_start.sh" "$TD/scripts/on_session_start.sh"

PAYLOAD='{"session_id":"sid-abc","cwd":"/tmp/project"}'

reset_calls() { : > "$CALLS"; }

# The hooks background the call, so give it a bounded moment to land.
wait_for_call() {
  local i=0
  while [ "$i" -lt 60 ]; do
    [ -s "$CALLS" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

calls() { cat "$CALLS" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }

# The env must be SCRUBBED, not merely added to. This suite runs inside a tmux
# pane under a Claude session, so TMUX and TMUX_PANE are already set in the
# ambient environment — and the first run of this file "failed" the no-TMUX_PANE
# assertions by reconciling THE TEST RUNNER'S OWN PANE (%359). That is the
# live-server hazard in miniature: inherited tmux variables make a hook look
# wired when it is only inheriting.
_scrub() { env -u TMUX -u TMUX_PANE -u CLAUDISH_ACTIVE_MODEL_NAME "$@"; }

run_stop() { # <extra env assignments…> — payload on stdin
  printf '%s' "$PAYLOAD" \
    | _scrub PATH="$TD/bin:$PATH" "$@" bash "$TD/scripts/on_stop.sh" >/dev/null 2>&1
}
run_start() { # <extra env assignments…>
  printf '%s' "${START_PAYLOAD:-$PAYLOAD}" \
    | _scrub PATH="$TD/bin:$PATH" CC_TAB_RECONCILE_DELAY=0 "$@" \
        bash "$TD/scripts/on_session_start.sh" >/dev/null 2>&1
}
# Same, but the hook's own stdout+stderr are captured rather than discarded.
noise_stop() {
  printf '%s' "$PAYLOAD" \
    | _scrub PATH="$TD/bin:$PATH" "$@" bash "$TD/scripts/on_stop.sh" 2>&1
}
noise_start() {
  printf '%s' "$PAYLOAD" \
    | _scrub PATH="$TD/bin:$PATH" CC_TAB_RECONCILE_DELAY=0 "$@" \
        bash "$TD/scripts/on_session_start.sh" 2>&1
}

echo "=== the producers call the one consumer ==="

# ── 1. The Stop hook (lifecycle 6.2 / 6.3) ───────────────────────────────────
echo ""
echo "1. Stop hook"

reset_calls
run_stop TMUX=/tmp/fake,1,0 TMUX_PANE=%42
if wait_for_call && [ "$(calls)" = "%42" ]; then
  ok "Stop reconciles ITS OWN pane's window (%42)"
else
  no "Stop reconciles ITS OWN pane's window (%42)" "calls=[$(calls)]"
fi

# THE REASON THIS CALL SITS ABOVE THE EARLY EXITS. Every exit further down
# on_stop.sh gates on the POSITION-keyed sidecar (#S-#I-#P), which drifts across
# a renumber or a restore. If the reconcile were appended at the end of the file
# instead, the tab would stop refreshing for exactly the sessions whose sidecar
# went missing — silently, and permanently until some other trigger fired.
reset_calls
rm -f "$TD/panes"/*.session-id 2>/dev/null
run_stop TMUX=/tmp/fake,1,0 TMUX_PANE=%42
if wait_for_call; then
  ok "Stop still reconciles when the pane's sidecar file does NOT exist"
else
  no "Stop still reconciles when the pane's sidecar file does NOT exist" \
     "no call recorded — the reconcile has slipped below an early exit"
fi

reset_calls
run_stop TMUX=/tmp/fake,1,0 TMUX_PANE=%42 CLAUDISH_ACTIVE_MODEL_NAME=some-model
if wait_for_call; then
  ok "Stop still reconciles for a claudish-spawned session (it owns a real pane)"
else
  no "Stop still reconciles for a claudish-spawned session" "no call recorded"
fi

# An empty -t is NOT an error to tmux: it means "the active pane of the current
# client". A Claude running outside tmux would therefore repaint whatever window
# the user happens to be looking at — the same trap that once made a non-tmux
# session claim a live pane's sidecar.
reset_calls
run_stop TMUX=/tmp/fake,1,0
sleep 0.3
if [ ! -s "$CALLS" ]; then
  ok "Stop does NOTHING with no TMUX_PANE (never repaints someone else's window)"
else
  no "Stop does NOTHING with no TMUX_PANE" "calls=[$(calls)]"
fi

reset_calls
run_stop TMUX_PANE=%42
sleep 0.3
if [ ! -s "$CALLS" ]; then
  ok "Stop does NOTHING outside tmux"
else
  no "Stop does NOTHING outside tmux" "calls=[$(calls)]"
fi

# ── 2. The SessionStart hook (lifecycle 6.1) ─────────────────────────────────
echo ""
echo "2. SessionStart hook"

reset_calls
run_start TMUX=/tmp/fake,1,0 TMUX_PANE=%7
if wait_for_call && [ "$(calls)" = "%7" ]; then
  ok "SessionStart reconciles its own pane's window (%7)"
else
  no "SessionStart reconciles its own pane's window (%7)" "calls=[$(calls)]"
fi

reset_calls
START_PAYLOAD='{"session_id":"sid-abc","cwd":"/tmp/project","agent_type":"general-purpose"}' \
  run_start TMUX=/tmp/fake,1,0 TMUX_PANE=%7
sleep 0.3
if [ ! -s "$CALLS" ]; then
  ok "a SUBAGENT session paints nothing (it occupies no pane)"
else
  no "a SUBAGENT session paints nothing" "calls=[$(calls)]"
fi

reset_calls
run_start TMUX=/tmp/fake,1,0
sleep 0.3
if [ ! -s "$CALLS" ]; then
  ok "SessionStart does NOTHING with no TMUX_PANE"
else
  no "SessionStart does NOTHING with no TMUX_PANE" "calls=[$(calls)]"
fi

# ── 3. The catalogue of producers ────────────────────────────────────────────
# The event-driven trade-off accepted here is "no single place shows what paints
# a tab", mitigated by every producer calling the SAME script. That mitigation
# is only true while this grep is complete.
echo ""
echo "3. the catalogue is complete"
for f in on_session_start.sh on_stop.sh post_restore.sh; do
  if grep -q 'cc_tab_reconcile' "$ROOT/scripts/$f"; then
    ok "scripts/$f is a producer"
  else
    no "scripts/$f is a producer" "no reference to cc_tab_reconcile"
  fi
done

if grep -q 'cc_tab_reconcile.*--all' "$ROOT/scripts/post_restore.sh"; then
  ok "post_restore reconciles --all (resurrect does not persist window options)"
else
  no "post_restore reconciles --all" "expected an --all call in post_restore.sh"
fi

# Every producer must stay SILENT. A Claude hook that writes to stdout confuses
# the client, and output from a tmux `run-shell` can take the server into the
# proc_send SIGSEGV that has twice destroyed every session on this machine.
# Asserted behaviourally rather than by grepping for a redirect, because in
# on_session_start.sh the redirect is on the enclosing subshell and no
# line-oriented grep can see that.
echo ""
echo "3b. the producers are silent"
reset_calls
out="$(noise_stop TMUX=/tmp/fake,1,0 TMUX_PANE=%42)"
if [ -z "$out" ]; then ok "on_stop.sh prints nothing"
else no "on_stop.sh prints nothing" "output: $out"; fi

reset_calls
out="$(noise_start TMUX=/tmp/fake,1,0 TMUX_PANE=%7)"
if [ -z "$out" ]; then ok "on_session_start.sh prints nothing"
else no "on_session_start.sh prints nothing" "output: $out"; fi

# post_restore.sh is far too large to run here; its one call site is checked
# directly, and it is a single line so a grep CAN see the redirect.
# shellcheck disable=SC2016
# The single quotes are deliberate: this is a literal grep PATTERN containing
# a dollar sign, not a shell expansion.
line="$(grep -n '"\$_cc_tab_reconcile" --all' "$ROOT/scripts/post_restore.sh" || true)"
case "$line" in
  *'>/dev/null 2>&1'*) ok "post_restore.sh's reconcile call is redirected" ;;
  '') no "post_restore.sh's reconcile call is redirected" "no --all call site found" ;;
  *)  no "post_restore.sh's reconcile call is redirected" "$line" ;;
esac

# ── 4. Anti-vacuity ──────────────────────────────────────────────────────────
# Four assertions above are "the stub was NOT called". If the stub could never
# be called — wrong path, not executable — all four would pass for free.
echo ""
echo "4. anti-vacuity"
reset_calls
run_stop TMUX=/tmp/fake,1,0 TMUX_PANE=%1
if wait_for_call; then
  ok "the stub detector is not vacuous (it records a call when there is one)"
else
  no "the stub detector is not vacuous" "the stub was never reachable"
fi

printf '\n  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
