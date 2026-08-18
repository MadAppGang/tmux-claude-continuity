#!/usr/bin/env bash
# pre_restore_launch_purge.sh — regression test for the blanket launch-file purge.
#
# pre_restore.sh deleted EVERY recorded launch-command file unconditionally. That
# is correct before a fresh-server restore (pane ids restart at %0, so a dead
# server's file would be attributed to whatever pane inherits that id) and wrong
# everywhere else — because .tmux.conf also calls this script from a bare
# `run-shell`, which fires on every config parse, not only before a restore.
#
# Measured on 2026-08-18: 47 files purged at 12:05:49 with no BOOT VERDICT after
# it, and the 21:19 snapshot carried CLAUDE_CMD on 1 of 41 Claude rows. Every
# restore logged `cmd=default`, so @claude-continuity-claude-cmd carried 100% of
# the relaunches and the typed-command path looked like it had never worked.
#
# The fix keys the decision on the tmux SERVER START TIME: a file written by a
# shell in this server is newer than the server and must survive; a dead server's
# residue is older and must go.
#
# Isolation: `tmux` is shimmed entirely, so this never contacts a real server.
#
# Usage: bash tests/pre_restore_launch_purge.sh   (exit 0 = pass)

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/pre_restore.sh"
[ -x "$SCRIPT" ] || { echo "ABORT: $SCRIPT not executable"; exit 1; }

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }

TD="$(mktemp -d /tmp/ccprlp-XXXXXX)" || exit 1
trap 'rm -rf "$TD"' EXIT INT TERM HUP

SERVER_START=1000000000          # fixed epoch for the fake server

# ── tmux shim ────────────────────────────────────────────────────────────────
# Answers only what pre_restore.sh asks: the two dirs, the log file, and
# #{start_time}. START_TIME_MODE=absent simulates tmux < 3.2.
mkdir -p "$TD/bin"
cat > "$TD/bin/tmux" <<EOF
#!/bin/sh
case "\$1 \$3" in
  "show-option @claude-continuity-launch-dir")  printf '%s\n' "$TD/launch"; exit 0 ;;
  "show-option @claude-continuity-pending-dir") printf '%s\n' "$TD/pending"; exit 0 ;;
  "show-option @claude-continuity-log-file")    printf '%s\n' "$TD/restore.log"; exit 0 ;;
esac
if [ "\$1" = "display-message" ]; then
  [ "\${START_TIME_MODE:-present}" = "absent" ] && exit 1
  printf '%s\n' "$SERVER_START"; exit 0
fi
exit 0
EOF
chmod +x "$TD/bin/tmux"

reset_dirs() {
  rm -rf "$TD/launch" "$TD/pending"
  mkdir -p "$TD/launch" "$TD/pending"
}

# mkfile <name> <mtime-epoch> [content]
mkfile() {
  printf '%s\n' "${3:-c --resume abc}" > "$TD/launch/$1"
  touch -t "$(date -r "$2" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$2" '+%Y%m%d%H%M.%S')" "$TD/launch/$1"
}

run_pre_restore() { TMUX_CMD="$TD/bin/tmux" PATH="$TD/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1; }

# ── 1. THE REGRESSION: a file written in THIS server must survive ────────────
reset_dirs
mkfile 42 $((SERVER_START + 500)) 'ck --resume live'
run_pre_restore
if [ -f "$TD/launch/42" ]; then
  ok "keeps a launch file written after server start (config reload)"
else
  no "keeps a launch file written after server start (config reload)" \
     "file 42 was deleted — a config reload still destroys live panes' commands"
fi

# ── 2. Dead-server residue must still be dropped ─────────────────────────────
reset_dirs
mkfile 7 $((SERVER_START - 3600)) 'c --resume dead'
run_pre_restore
if [ -f "$TD/launch/7" ]; then
  no "drops a launch file older than server start (fresh-server restore)" \
     "file 7 survived — a dead server's command can be attributed to a new pane"
else
  ok "drops a launch file older than server start (fresh-server restore)"
fi

# ── 3. Mixed set: keep the new, drop the old, in one run ─────────────────────
reset_dirs
mkfile 1 $((SERVER_START - 60))  'c old'
mkfile 2 $((SERVER_START + 60))  'ck new'
mkfile 3 $((SERVER_START - 999)) 'c older'
run_pre_restore
if [ ! -f "$TD/launch/1" ] && [ -f "$TD/launch/2" ] && [ ! -f "$TD/launch/3" ]; then
  ok "mixed set partitions correctly on server start time"
else
  no "mixed set partitions correctly on server start time" \
     "present: $(ls "$TD/launch" 2>/dev/null | tr '\n' ' ')"
fi

# ── 4. Fallback: no #{start_time} (tmux < 3.2) → blanket purge preserved ─────
reset_dirs
mkfile 8 $((SERVER_START + 500)) 'ck --resume live'
START_TIME_MODE=absent run_pre_restore
if [ -f "$TD/launch/8" ]; then
  no "blanket-purges when start_time is unavailable" \
     "file 8 survived without a usable discriminator — unsafe on a fresh server"
else
  ok "blanket-purges when start_time is unavailable (safe fallback)"
fi

# ── 5. Non-pane filenames are never touched ──────────────────────────────────
reset_dirs
printf 'keep me\n' > "$TD/launch/README"
mkfile 9 $((SERVER_START - 10)) 'c old'
run_pre_restore
if [ -f "$TD/launch/README" ] && [ ! -f "$TD/launch/9" ]; then
  ok "leaves non-digit filenames alone while purging stale pane files"
else
  no "leaves non-digit filenames alone while purging stale pane files" \
     "present: $(ls "$TD/launch" 2>/dev/null | tr '\n' ' ')"
fi

# ── 6. The log distinguishes kept from purged ────────────────────────────────
reset_dirs
mkfile 11 $((SERVER_START + 5)) 'ck a'
mkfile 12 $((SERVER_START - 5)) 'c b'
run_pre_restore
if grep -q 'kept 1 written in this server' "$TD/restore.log" 2>/dev/null; then
  ok "logs how many files were kept, not just purged"
else
  no "logs how many files were kept, not just purged" \
     "log: $(grep 'launch-command' "$TD/restore.log" 2>/dev/null | tail -1)"
fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
