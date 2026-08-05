#!/usr/bin/env bash
# claudish_restore.sh — post_restore.sh reconstruction test for CLAUDISH panes
# and the @claude-continuity-restore-procs passthrough.
#
# Asserts on the EXACT pending-file contents. Panes run a shell wrapping an inert
# loop (see _mkpane): a shell so post_restore's busy-pane guard does not skip
# them, inert so nothing consumes the pending file and we can read back precisely
# what post_restore wrote.
#
# Isolation: -f /dev/null, all state under $TMPROOT, never kill-server.
# Usage: bash tests/claudish_restore.sh

set -uo pipefail

SOCKET="tccl$$"
TMPROOT="/tmp/tccl-$$"
PANES_DIR="$TMPROOT/panes"
PENDING_DIR="$TMPROOT/pending"
RESURRECT_DIR="$TMPROOT/resurrect"
RF="$RESURRECT_DIR/last"
LOG="$TMPROOT/restore.log"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
RESTORE="$SCRIPT_DIR/post_restore.sh"

case "$SOCKET" in default|"") echo "unsafe socket"; exit 1 ;; esac
_t() { tmux -L "$SOCKET" "$@"; }

cleanup() {
  for s in $(_t list-sessions -F '#{session_name}' 2>/dev/null); do _t kill-session -t "$s" 2>/dev/null; done
  for p in $(ps -Ao pid,command= | awk -v s="-L $SOCKET" '$2 ~ /(^|\/)tmux$/ && index($0,s){print $1}'); do kill "$p" 2>/dev/null; done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

pass=0; fail=0
ok(){ echo "  PASS: $1"; pass=$((pass+1)); }
no(){ echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "     $2"; fail=$((fail+1)); }

mkdir -p "$PANES_DIR/by-pid" "$PENDING_DIR" "$RESURRECT_DIR"

# One isolated server for all cases; each case gets its own single-pane session
# running `sleep`, so the pending file persists (no interactive precmd consumes).
_t -f /dev/null new-session -d -s _seed -c /tmp "sleep 600"
_t set-option -g @claude-continuity-panes-dir    "$PANES_DIR"
_t set-option -g @claude-continuity-pending-dir  "$PENDING_DIR"
_t set-option -g @claude-continuity-log-file     "$LOG"
_t set-option -g @resurrect-dir                  "$RESURRECT_DIR"
_t set-option -g @claude-continuity-claude-cmd   "echo"
_t set-option -g @claude-continuity-claudish-cmd "claudish"

n="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
[ "$n" = "1" ] && echo "isolation: PASS (1 session)" || { echo "isolation FAIL ($n)"; exit 1; }

# Make a fresh single-pane session named $1; echo "w|p|id|cwd|title".
#
# The pane must run a SHELL, not a bare `sleep`. post_restore skips any pane
# already running a program ("not a restored shell — not arming"), because on a
# live server that pane is not a restored bare shell and arming it would both
# relaunch over a running Claude and send Enter into a half-typed prompt. A bare
# `sleep` trips that guard and every case here silently resolves to nothing.
# `sh` wrapping an inert loop satisfies the guard while still never consuming the
# pending file: the precmd hook lives in ~/.zshrc, which this -f /dev/null server
# never sources, so the file stays on disk for us to read back.
_mkpane() {
  local name="$1"
  _t new-session -d -s "$name" -c /tmp "sh -c 'while :; do sleep 5; done'"
  _t list-panes -t "$name" -F '#{window_index}|#{pane_index}|#{pane_id}|#{pane_current_path}|#{pane_title}' | head -1
}

# Run post_restore against a one-row snapshot and return the pending file path.
_run_one() {
  : > "$LOG"
  TMUX_CMD="tmux -L $SOCKET" RESURRECT_FILE="$RF" bash "$RESTORE" >/dev/null 2>&1
}

# ── Case A: claudish explicit-model pane ─────────────────────────────────────
echo "Case A: claudish --model … resumes via claudish (not bare claude)"
IFS='|' read -r w p id cwd title < <(_mkpane cA)
printf 'pane\tcA\t%s\t1\t:*\t%s\t%s\t:%s\t1\tnode\t:node /Users/jack/.bun/bin/claudish --model cx@gpt-5.6-sol -d\t;CLAUDE_SID=sid-aaa\t;CLAUDISH_REPLAY=--model cx@gpt-5.6-sol -d\n' \
  "$w" "$p" "$title" "$cwd" > "$RF"
_run_one
pfA="$PENDING_DIR/${id#%}"
got="$(cat "$pfA" 2>/dev/null)"
[ "$got" = "claudish --model cx@gpt-5.6-sol -d --resume sid-aaa" ] \
  && ok "pending = [$got]" || no "wrong pending" "got: [$got]"
grep -q 'claudish resume=sid-aaa' "$LOG" && ok "log records claudish resume" || no "log missing claudish resume"

# ── Case B: claudish interactive pane (model already injected into replay) ───
echo "Case B: interactive claudish (model injected) round-trips"
IFS='|' read -r w p id cwd title < <(_mkpane cB)
printf 'pane\tcB\t%s\t1\t:*\t%s\t%s\t:%s\t1\tnode\t:node /Users/jack/.bun/bin/claudish -d\t;CLAUDE_SID=sid-bbb\t;CLAUDISH_REPLAY=-d --model g@gemini-3-pro\n' \
  "$w" "$p" "$title" "$cwd" > "$RF"
_run_one
got="$(cat "$PENDING_DIR/${id#%}" 2>/dev/null)"
[ "$got" = "claudish -d --model g@gemini-3-pro --resume sid-bbb" ] \
  && ok "pending = [$got]" || no "wrong pending" "got: [$got]"

# ── Case C: plain claude pane (no replay) stays on the claude base cmd ────────
echo "Case C: plain claude pane is NOT rewritten to claudish"
IFS='|' read -r w p id cwd title < <(_mkpane cC)
printf 'pane\tcC\t%s\t1\t:*\t%s\t%s\t:%s\t1\tclaude\t:claude\t;CLAUDE_SID=sid-ccc\n' \
  "$w" "$p" "$title" "$cwd" > "$RF"
_run_one
got="$(cat "$PENDING_DIR/${id#%}" 2>/dev/null)"
case "$got" in
  *"--resume sid-ccc") case "$got" in *claudish*) no "plain claude got claudish" "[$got]" ;; *) ok "pending = [$got]" ;; esac ;;
  *) no "plain claude not resumed" "[$got]" ;;
esac

# ── Case D: restore_procs relaunches a codex pane verbatim ───────────────────
echo "Case D: @claude-continuity-restore-procs relaunches codex verbatim"
_t set-option -g @claude-continuity-restore-procs "codex lazygit"
IFS='|' read -r w p id cwd title < <(_mkpane cD)
printf 'pane\tcD\t%s\t1\t:*\t%s\t%s\t:%s\t1\tcodex\t:codex --model gpt-5 resume\n' \
  "$w" "$p" "$title" "$cwd" > "$RF"
_run_one
got="$(cat "$PENDING_DIR/${id#%}" 2>/dev/null)"
[ "$got" = "codex --model gpt-5 resume" ] && ok "pending = [$got]" || no "wrong proc pending" "[$got]"

# ── Case E: a non-listed program is NOT restored ─────────────────────────────
echo "Case E: an unlisted program (vim) is left alone"
IFS='|' read -r w p id cwd title < <(_mkpane cE)
printf 'pane\tcE\t%s\t1\t:*\t%s\t%s\t:%s\t1\tvim\t:vim /tmp/x\n' \
  "$w" "$p" "$title" "$cwd" > "$RF"
_run_one
if [ -e "$PENDING_DIR/${id#%}" ]; then no "vim pane wrongly restored" "[$(cat "$PENDING_DIR/${id#%}")]"
else ok "vim pane left alone (no pending file)"; fi

echo ""
echo "══ Results: $pass passed, $fail failed ══"
[ "$fail" -eq 0 ]
