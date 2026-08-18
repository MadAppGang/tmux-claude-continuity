#!/usr/bin/env bash
# pre_restore_launch_socket.sh — the launch-command purge against a REAL tmux.
#
# tests/pre_restore_launch_purge.sh shims tmux to exercise the decision quickly.
# This one proves the same behaviour end to end on a real server, because the two
# assumptions the fix rests on can only be checked against real tmux:
#
#   1. `#{start_time}` exists, is numeric, and is the SERVER's start — not the
#      session's, not the client's.
#   2. A real zsh pane running the continuity hook writes its launch file with an
#      mtime NEWER than that server start, so the discriminator keeps it.
#
# The headline case is the one that was broken in production: a pane records
# `c …` through preexec, a config parse fires pre_restore.sh (which .tmux.conf
# does on EVERY `tmux source-file`, not only before a restore), and the recorded
# command must still be there afterwards.
#
# Isolation: own socket with `-f /dev/null`, own dirs, own log, fake `claude` on
# a private PATH. Never contacts the default server; the default server's session
# and pane counts are fingerprinted before and after and must not move.
#
# Usage: bash tests/pre_restore_launch_socket.sh   (exit 0 = pass)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/pre_restore.sh"
HOOK="$ROOT/claude-continuity.zsh"
[ -x "$SCRIPT" ] || { echo "ABORT: $SCRIPT not executable"; exit 1; }
[ -f "$HOOK" ]   || { echo "ABORT: $HOOK missing"; exit 1; }
command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not installed"; exit 0; }

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

SOCKET="ccpls$$"
case "$SOCKET" in default|"") echo "ABORT: unsafe socket [$SOCKET]"; exit 1 ;; esac
TD="$(mktemp -d /tmp/ccpls-XXXXXX)" || exit 1
_tmux() { tmux -L "$SOCKET" "$@"; }

cleanup() { _tmux kill-server 2>/dev/null; rm -rf "$TD"; }
trap cleanup EXIT INT TERM HUP

# ── fingerprint the REAL server: this test must not disturb it ───────────────
fp() { tmux list-sessions 2>/dev/null | wc -l | tr -d ' '; tmux list-panes -a 2>/dev/null | wc -l | tr -d ' '; }
FP_BEFORE="$(fp)"

mkdir -p "$TD/launch" "$TD/pending" "$TD/bin" "$TD/zdot"

# A fake claude, so the alias resolves as a Claude launcher and running it is inert.
printf '#!/bin/sh\nexit 0\n' > "$TD/bin/claude"; chmod +x "$TD/bin/claude"

# A private zsh rc that installs exactly what the hook needs: the alias whose
# text names claude (that is what _claude_continuity_record classifies on), and
# the hook itself.
cat > "$TD/zdot/.zshrc" <<EOF
export PATH="$TD/bin:\$PATH"
alias c='claude --dangerously-skip-permissions'
source "$HOOK"
EOF

echo "=== pre_restore.sh — real tmux socket ($SOCKET) ==="

# The user's REAL launch dir. Nothing here may write to it; asserted at the end.
REAL_LD="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-claude/launch"
real_ld_fp() { ls -1 "$REAL_LD" 2>/dev/null | sort | md5 2>/dev/null || ls -1 "$REAL_LD" 2>/dev/null | sort | md5sum; }
REAL_LD_BEFORE="$(real_ld_fp)"

# ── boot an isolated server with an INERT pane FIRST ─────────────────────────
# The order here is load-bearing. claude-continuity.zsh resolves both dirs ONCE,
# at source time, from tmux options. A zsh pane started before those options are
# set resolves them to the DEFAULTS — the user's real ~/.config/tmux-claude — and
# then writes its captured command there. That is not hypothetical: the first run
# of this test left a fabricated `launch/0` in the live directory. So boot inert,
# configure the server, and only then start zsh.
_tmux -f /dev/null new-session -d -s t -c "$TD" 'sh -c "while :; do sleep 30; done"' 2>/dev/null
sleep 1
if ! _tmux list-sessions >/dev/null 2>&1; then
  echo "ABORT: test server did not start"; exit 1
fi
_tmux set-option -g @claude-continuity-launch-dir  "$TD/launch"
_tmux set-option -g @claude-continuity-pending-dir "$TD/pending"
_tmux set-option -g @claude-continuity-log-file    "$TD/restore.log"

# Verify the options took before any zsh can read them.
if [ "$(_tmux show-option -gqv @claude-continuity-launch-dir)" != "$TD/launch" ]; then
  echo "ABORT: launch-dir option did not take; refusing to start zsh"; exit 1
fi

run_pre_restore() { TMUX_CMD="tmux -L $SOCKET" bash "$SCRIPT" >/dev/null 2>&1; }

# ── 1. #{start_time} is real, numeric, and plausible ─────────────────────────
ST="$(_tmux display-message -p '#{start_time}' 2>/dev/null)"
NOW="$(date +%s)"
if [ -n "$ST" ] && [ "$ST" -eq "$ST" ] 2>/dev/null && [ "$ST" -le "$NOW" ] && [ "$ST" -gt $((NOW - 300)) ]; then
  ok "real tmux reports a numeric #{start_time} ($(date -r "$ST" '+%H:%M:%S'))"
else
  no "real tmux reports a numeric #{start_time}" "got [$ST], now [$NOW] — discriminator unavailable on this tmux"
fi

# ── 2. THE PRODUCTION CASE: a real pane records, a config parse must not erase ──
# Start zsh only now that the dirs are configured, and capture its pane id
# directly from new-window rather than guessing which pane is which.
PANE="$(_tmux new-window -t t -c "$TD" -P -F '#{pane_id}' "ZDOTDIR=$TD/zdot zsh" 2>/dev/null)"
KEY="${PANE#%}"
sleep 1
_tmux send-keys -t "$PANE" 'c' C-m 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -f "$TD/launch/$KEY" ] && break
  sleep 0.4
done

if [ -f "$TD/launch/$KEY" ]; then
  ok "a real zsh pane records its typed command via preexec ($(cat "$TD/launch/$KEY"))"

  run_pre_restore
  if [ -f "$TD/launch/$KEY" ]; then
    ok "config parse (pre_restore) KEEPS the live pane's recorded command"
  else
    no "config parse (pre_restore) KEEPS the live pane's recorded command" \
       "the production bug is back: every tmux source-file erases live captures"
  fi

  # The recorded text must be the ALIAS as typed, not the expanded binary.
  if [ "$(cat "$TD/launch/$KEY")" = "c" ]; then
    ok "records the alias as typed, not its expansion"
  else
    no "records the alias as typed, not its expansion" "got [$(cat "$TD/launch/$KEY")]"
  fi

  # ── 3. Backdate that same real file → dead-server residue → must go ────────
  touch -t "$(date -r $((ST - 3600)) '+%Y%m%d%H%M.%S')" "$TD/launch/$KEY"
  run_pre_restore
  if [ -f "$TD/launch/$KEY" ]; then
    no "purges a recorded command older than server start" \
       "residue survived — it could be attributed to a new pane at this id"
  else
    ok "purges a recorded command older than server start"
  fi
else
  no "a real zsh pane records its typed command via preexec" \
     "no file at $TD/launch/$KEY — hook did not fire; later cases skipped"
fi

# ── 4. Mixed set against the real server ─────────────────────────────────────
rm -f "$TD/launch"/*
printf 'ck new\n' > "$TD/launch/900"
printf 'c old\n'  > "$TD/launch/901"
touch -t "$(date -r $((ST - 7200)) '+%Y%m%d%H%M.%S')" "$TD/launch/901"
run_pre_restore
if [ -f "$TD/launch/900" ] && [ ! -f "$TD/launch/901" ]; then
  ok "partitions correctly against a real server start time"
else
  no "partitions correctly against a real server start time" \
     "present: $(ls "$TD/launch" 2>/dev/null | tr '\n' ' ')"
fi

# ── 5. The log reflects the real run ─────────────────────────────────────────
if grep -q 'kept' "$TD/restore.log" 2>/dev/null; then
  ok "logs the kept count on a real run"
else
  no "logs the kept count on a real run" "log: $(tail -1 "$TD/restore.log" 2>/dev/null)"
fi

# ── 6. The real server and the real launch dir were never disturbed ──────────
FP_AFTER="$(fp)"
if [ "$FP_BEFORE" = "$FP_AFTER" ]; then
  ok "default tmux server untouched (sessions/panes unchanged)"
else
  no "default tmux server untouched" "before [$(echo $FP_BEFORE)] after [$(echo $FP_AFTER)]"
fi

# The guard for the contamination this test itself caused on its first run.
if [ "$REAL_LD_BEFORE" = "$(real_ld_fp)" ]; then
  ok "user's real launch dir untouched"
else
  no "user's real launch dir untouched" \
     "$REAL_LD changed — a test pane resolved the DEFAULT dirs and wrote there"
fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
