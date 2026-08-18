#!/usr/bin/env bash
# pre_restore_launch_purge.sh — the launch-command purge decision, exhaustively.
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
# This file covers the DECISION in isolation: `tmux` is shimmed, so it is fast
# and never contacts a real server. tests/pre_restore_launch_socket.sh proves the
# same behaviour against a real tmux, including a real zsh pane recording its own
# command through the preexec hook.
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

SERVER_START=1600000000          # fixed epoch for the fake server

# ── tmux shim ────────────────────────────────────────────────────────────────
# Answers only what pre_restore.sh asks: the two dirs, the log file, and
# #{start_time}. START_TIME_MODE controls the discriminator's availability:
#   present (default) | absent (command fails, tmux < 3.2)
#   empty (prints nothing) | garbage (non-numeric) | padded (surrounding space)
mkdir -p "$TD/bin"
cat > "$TD/bin/tmux" <<EOF
#!/bin/sh
case "\$1 \$3" in
  "show-option @claude-continuity-launch-dir")  printf '%s\n' "$TD/launch"; exit 0 ;;
  "show-option @claude-continuity-pending-dir") printf '%s\n' "$TD/pending"; exit 0 ;;
  "show-option @claude-continuity-log-file")    printf '%s\n' "$TD/restore.log"; exit 0 ;;
esac
if [ "\$1" = "display-message" ]; then
  case "\${START_TIME_MODE:-present}" in
    absent)  exit 1 ;;
    empty)   printf '' ; exit 0 ;;
    garbage) printf 'not-a-number\n'; exit 0 ;;
    padded)  printf '  %s  \n' "$SERVER_START"; exit 0 ;;
    *)       printf '%s\n' "$SERVER_START"; exit 0 ;;
  esac
fi
exit 0
EOF
chmod +x "$TD/bin/tmux"

reset_dirs() { rm -rf "$TD/launch" "$TD/pending"; mkdir -p "$TD/launch" "$TD/pending"; }

# mkfile <name> <mtime-epoch> [content]
mkfile() {
  printf '%s\n' "${3:-c --resume abc}" > "$TD/launch/$1"
  touch -t "$(date -r "$2" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$2" '+%Y%m%d%H%M.%S')" "$TD/launch/$1"
}

run_pre_restore() { TMUX_CMD="$TD/bin/tmux" PATH="$TD/bin:$PATH" bash "$SCRIPT" >/dev/null 2>&1; }

exists()  { [ -f "$TD/launch/$1" ]; }
present() { ls "$TD/launch" 2>/dev/null | tr '\n' ' '; }

echo "=== pre_restore.sh — launch-command purge decision ==="

# ── A. The discriminator ─────────────────────────────────────────────────────
reset_dirs; mkfile 42 $((SERVER_START + 500)) 'ck --resume live'; run_pre_restore
exists 42 && ok "keeps a file written AFTER server start (config reload)" \
           || no "keeps a file written AFTER server start (config reload)" \
                 "file 42 deleted — a config reload still destroys live panes' commands"

reset_dirs; mkfile 7 $((SERVER_START - 3600)) 'c --resume dead'; run_pre_restore
exists 7 && no "drops a file written BEFORE server start (dead-server residue)" \
               "file 7 survived — a dead server's command can be attributed to a new pane" \
          || ok "drops a file written BEFORE server start (dead-server residue)"

# Boundary: written in the same second the server started. `-ge` keeps it; a pane
# cannot predate its own server, so equality means "this server".
reset_dirs; mkfile 5 $SERVER_START 'c boundary'; run_pre_restore
exists 5 && ok "keeps a file whose mtime EQUALS server start (boundary)" \
         || no "keeps a file whose mtime EQUALS server start (boundary)" "file 5 deleted"

reset_dirs
mkfile 1 $((SERVER_START - 60)) 'c old'
mkfile 2 $((SERVER_START + 60)) 'ck new'
mkfile 3 $((SERVER_START - 999)) 'c older'
mkfile 4 $((SERVER_START + 999)) 'ck newer'
run_pre_restore
if ! exists 1 && exists 2 && ! exists 3 && exists 4; then
  ok "mixed set partitions correctly in one run"
else
  no "mixed set partitions correctly in one run" "present: $(present)"
fi

# ── B. Discriminator unavailable → blanket purge (the safe fallback) ─────────
for mode in absent empty garbage; do
  reset_dirs; mkfile 8 $((SERVER_START + 500)) 'ck live'
  START_TIME_MODE=$mode run_pre_restore
  exists 8 && no "blanket-purges when start_time is $mode" \
                 "file 8 survived without a usable discriminator — unsafe on a fresh server" \
            || ok "blanket-purges when start_time is $mode (safe fallback)"
done

# tmux prints the format with a trailing newline; $( ) strips it. Surrounding
# spaces must NOT be mistaken for garbage, or every reload silently blanket-purges.
reset_dirs; mkfile 9 $((SERVER_START + 500)) 'ck live'
START_TIME_MODE=padded run_pre_restore
exists 9 && ok "tolerates whitespace around start_time" \
         || no "tolerates whitespace around start_time" \
               "padded value treated as garbage — every reload would blanket-purge"

# ── C. Filename filtering ────────────────────────────────────────────────────
reset_dirs
printf 'keep me\n' > "$TD/launch/README"
printf 'keep me\n' > "$TD/launch/.hidden"
mkfile 10 $((SERVER_START - 10)) 'c old'
run_pre_restore
if [ -f "$TD/launch/README" ] && [ -f "$TD/launch/.hidden" ] && ! exists 10; then
  ok "never touches non-pane filenames"
else
  no "never touches non-pane filenames" "present: $(present)"
fi

reset_dirs; mkfile 007 $((SERVER_START - 10)) 'c old'; run_pre_restore
exists 007 && no "handles zero-padded pane ids" "007 survived" \
            || ok "handles zero-padded pane ids"

# A directory whose name is all digits must not be rm -f'd or crash the loop.
reset_dirs; mkdir -p "$TD/launch/55"; mkfile 56 $((SERVER_START + 5)) 'ck live'; run_pre_restore
if [ -d "$TD/launch/55" ] && exists 56; then
  ok "skips directories that look like pane ids"
else
  no "skips directories that look like pane ids" "present: $(present)"
fi

# ── D. Directory state ───────────────────────────────────────────────────────
reset_dirs; rm -rf "$TD/launch"
if run_pre_restore; then ok "exits 0 when the launch dir does not exist"
else no "exits 0 when the launch dir does not exist" "non-zero exit"; fi

reset_dirs
if run_pre_restore && [ -z "$(present)" ]; then ok "exits 0 on an empty launch dir"
else no "exits 0 on an empty launch dir" "non-zero exit or unexpected content"; fi

# ── E. Logging ───────────────────────────────────────────────────────────────
reset_dirs; mkfile 11 $((SERVER_START + 5)) 'ck a'; mkfile 12 $((SERVER_START - 5)) 'c b'
rm -f "$TD/restore.log"; run_pre_restore
grep -q 'purged 1 stale launch-command file(s)' "$TD/restore.log" 2>/dev/null \
  && grep -q 'kept 1 written in this server' "$TD/restore.log" 2>/dev/null \
  && ok "logs kept and purged counts when both occur" \
  || no "logs kept and purged counts when both occur" \
        "log: $(grep 'launch-command' "$TD/restore.log" 2>/dev/null | tail -1)"

reset_dirs; mkfile 13 $((SERVER_START - 5)) 'c b'
rm -f "$TD/restore.log"; run_pre_restore
if grep -q 'launch-command' "$TD/restore.log" 2>/dev/null && \
   ! grep -q 'kept' "$TD/restore.log" 2>/dev/null; then
  ok "omits the kept clause when nothing was kept"
else
  no "omits the kept clause when nothing was kept" \
     "log: $(grep 'launch-command' "$TD/restore.log" 2>/dev/null | tail -1)"
fi

# ── F. Regression guard: the pending purge is unchanged ──────────────────────
# Pending files are consumed by a precmd and must still be dropped wholesale —
# a stale one resumes a dead session's SID into whatever pane inherits its id.
reset_dirs
printf 'stale --resume sid-GHOST\n' > "$TD/pending/999"
mkfile 14 $((SERVER_START + 5)) 'ck live'
run_pre_restore
if [ ! -f "$TD/pending/999" ] && exists 14; then
  ok "still purges pending resumes wholesale (unchanged behaviour)"
else
  no "still purges pending resumes wholesale (unchanged behaviour)" \
     "pending: $(ls "$TD/pending" 2>/dev/null | tr '\n' ' ') launch: $(present)"
fi

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
