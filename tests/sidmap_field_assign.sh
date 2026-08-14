#!/usr/bin/env bash
# sidmap_field_assign.sh — L1 regression: a TAGGED-field read must never let a
# later field collapse into an earlier slot when an intermediate field is empty.
#
# The hazard (requirements FR6.1/FR6.2). The snapshot's optional columns are
# read positionally as extra1..extra3. TAB is IFS *whitespace*: `read` collapses
# runs of tabs and strips leading ones, so a row written as
#
#     …\t;CLAUDE_SID=uuid\t\t;CLAUDISH_REPLAY=-d          (empty CMD column)
#
# is seen by every reader as TWO extras, and the replay flags land in the slot
# the reader believes is ;CLAUDE_CMD=. One pane's launcher then restores as
# another pane's flags — silently, with no error anywhere.
#
# The contract (architecture §3.5): "A pane whose sidmap entry has an empty
# typed-command field now emits ;CLAUDISH_REPLAY=<flags> and NO ;CLAUDE_CMD=.
# Directly assertable from the snapshot text."
#
# So this test asserts BOTH halves of the fix, on the real emitted text:
#   (a) the writer never emits an empty TAB-separated field, and
#   (b) every optional column is sentinel-prefixed, so a reader keying on the
#       TAG (not on the position) recovers exactly what was written — for all
#       four present/absent combinations of the two optional columns.
# Phase 5 then carries the emitted row through post_restore.sh, because a field
# that is merely *present* but mis-assigned still produces the wrong relaunch.
#
# Black box: this test knows only the snapshot text and the pending-file text.
# It never reads a script.
#
# Isolation: own tmux socket, `-f /dev/null` (no ~/.tmux.conf, so no
# continuum-safe-restore can clone the live snapshot in), every directory under
# /tmp. See the PRE-FLIGHT GUARD.
#
# Usage: bash tests/sidmap_field_assign.sh   (exit 0 = pass)

set -uo pipefail

SOCKET="ccsm$$"
TD="/tmp/ccsm-$$"
PD="$TD/panes"
LD="$TD/launch"
QD="$TD/pending"
RD="$TD/resurrect"
BIN="$TD/bin"
FIX="$TD/fix"
SHIM="$TD/shim"
LOG="$TD/cc.log"
SNAP="$TD/snapshot.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
PRE_SAVE="$SCRIPT_DIR/pre_save.sh"
RESTORE="$SCRIPT_DIR/post_restore.sh"

TMUX_CMD_STR="tmux -L $SOCKET -f /dev/null"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass+1)); }
no()  { echo "  FAIL: $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail+1)); }
assert_eq() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$2], want [$3]"; fi
}
assert_has() { # <label> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "[$2] does not contain [$3]" ;; esac
}
assert_hasnt() { # <label> <haystack> <needle>
  case "$2" in *"$3"*) no "$1" "[$2] unexpectedly contains [$3]" ;; *) ok "$1" ;; esac
}

# ── PRE-FLIGHT GUARD ─────────────────────────────────────────────────────────
# Abort before touching anything if the isolation contract is not satisfied.
case "$SOCKET" in
  default|""|*/*|*\ *) echo "ABORT: unsafe socket name [$SOCKET]"; exit 1 ;;
  ccsm*) ;;
  *) echo "ABORT: [$SOCKET] is not this test's socket"; exit 1 ;;
esac
case "$TMUX_CMD_STR" in *"-L $SOCKET"*) ;; *) echo "ABORT: TMUX_CMD not on test socket"; exit 1 ;; esac
case "$TMUX_CMD_STR" in *"-f /dev/null"*) ;; *) echo "ABORT: TMUX_CMD lacks -f /dev/null"; exit 1 ;; esac
case "$TD" in /tmp/*) ;; *) echo "ABORT: temp root [$TD] is not under /tmp"; exit 1 ;; esac
for d in "$PD" "$LD" "$QD" "$RD"; do
  case "$d" in "$HOME"/*) echo "ABORT: [$d] is inside \$HOME"; exit 1 ;; esac
done
if tmux -L "$SOCKET" -f /dev/null list-sessions >/dev/null 2>&1; then
  echo "ABORT: socket $SOCKET already has a live server"; exit 1
fi

_t() { tmux -L "$SOCKET" -f /dev/null "$@"; }

_kill_fixtures() {
  ps -axo pid=,command= > "$TD/ps.exit" 2>/dev/null
  while read -r _p _rest; do
    [ -z "${_p:-}" ] && continue
    [ "$_p" = "$$" ] && continue
    case "$_rest" in *"$TD"*) kill -9 "$_p" 2>/dev/null ;; esac
  done < "$TD/ps.exit"
}
_teardown() {
  _t kill-server 2>/dev/null
  _kill_fixtures
  rm -rf "$TD"
}
trap _teardown EXIT INT TERM

mkdir -p "$PD/by-pid" "$LD" "$QD" "$RD" "$BIN" "$FIX" "$SHIM"

if [ ! -f "$PRE_SAVE" ]; then echo "ABORT: missing $PRE_SAVE"; exit 1; fi

# tmux shim: pre_save is contracted to use $TMUX_CMD, but a bare `tmux` on PATH
# must never reach the live server either. Belt and braces. $BIN (the fake
# claude/node binaries) is deliberately NOT on PATH.
cat > "$SHIM/tmux" <<EOF
#!/usr/bin/env bash
exec $(command -v tmux) -L "$SOCKET" -f /dev/null "\$@"
EOF
chmod +x "$SHIM/tmux"

# ── Fixtures: real process trees with the right EXEC TOKENS ──────────────────
# Symlinks to /bin/sh carry their own argv[0], so `ps -o command=` shows
# ".../node .../claudish --model … -d" and ".../claude …" — the exact token
# shapes the sid climb and the classifier key on. No real Claude is launched.
ln -s /bin/sh "$BIN/node"
ln -s /bin/sh "$BIN/op"
ln -s /bin/sh "$BIN/claude"
printf 'while :; do sleep 5; done\n' > "$FIX/loop.sh"
printf 'while :; do sleep 5; done\n' > "$FIX/claudish"
# op stays resident so claude is a GRANDCHILD of pane_pid (the `op run -- claude`
# alias shape); the trailing `:` defeats sh's exec optimisation.
printf '"%s/claude" "%s/loop.sh"\n:\n' "$BIN" "$FIX" > "$FIX/oprun.sh"

CLAUDISH_ARGS="--model cx@gpt-5.6-sol -d"

_t new-session -d -s work -c /tmp "sh -c '\"$BIN/node\" \"$FIX/claudish\" $CLAUDISH_ARGS; :'"
_t set-option -g base-index 1 >/dev/null
_t set-option -g pane-base-index 1 >/dev/null
_t set-option -g default-shell /bin/sh >/dev/null
_t set-option -g @claude-continuity-panes-dir   "$PD" >/dev/null
_t set-option -g @claude-continuity-launch-dir  "$LD" >/dev/null
_t set-option -g @claude-continuity-pending-dir "$QD" >/dev/null
_t set-option -g @claude-continuity-log-file    "$LOG" >/dev/null
_t set-option -g @claude-continuity-claude-cmd  "echo" >/dev/null
_t set-option -g @claude-continuity-claudish-cmd "claudish" >/dev/null
_t set-option -g @resurrect-dir                 "$RD" >/dev/null

# A second window whose pane runs claude behind the op wrapper.
_t new-window -t work -c /tmp "sh -c '\"$BIN/op\" \"$FIX/oprun.sh\"; :'"
# A third, parked on an inert SHELL loop (not a bare `sleep`: post_restore only
# arms panes that look like restored shells).
_t new-window -t work -c /tmp "sh -c 'while :; do sleep 5; done'"

# Isolation re-check: if ~/.tmux.conf had been sourced, continuum would have
# restored the live snapshot and this count would not be 1.
NS="$(_t list-sessions 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NS" != "1" ]; then echo "ABORT: expected 1 session on the test socket, found $NS"; exit 1; fi

# ── Resolve the real process tree ────────────────────────────────────────────
_descendants() { # <root pid> -> descendant pids, ONE PER LINE, root excluded
  ps -axo pid=,ppid= | awk -v r="$1" '
    { pid[NR]=$1; pp[$1]=$2; n=NR }
    END {
      q[1]=r; c=1; h=1
      while (h <= c) { cur=q[h]; h++
        for (i=1; i<=n; i++) if (pp[pid[i]] == cur) { c++; q[c]=pid[i] } }
      for (i=2; i<=c; i++) print q[i]
    }'
}
_pid_cmd() { ps -p "$1" -o command= 2>/dev/null; }

_find_desc_matching() { # <pane pid> <substring> -> first matching pid
  local p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    case "$(_pid_cmd "$p")" in *"$2"*) printf '%s' "$p"; return 0 ;; esac
  done < <(_descendants "$1")
  return 1
}

set --
while IFS= read -r _wi; do [ -n "$_wi" ] && set -- "$@" "$_wi"; done \
  < <(_t list-windows -t work -F '#{window_index}')
if [ "$#" -lt 3 ]; then echo "ABORT: expected 3 windows, got $#"; exit 1; fi
W_CLAUDISH="$1"; W_CLAUDE="$2"; W_SHELL="$3"

_pane_field() { _t list-panes -t "work:$1" -F "$2" | head -1; }

CLAUDISH_PANE_PID=""; CLAUDE_PANE_PID=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
  CLAUDISH_PANE_PID="$(_pane_field "$W_CLAUDISH" '#{pane_pid}')"
  CLAUDE_PANE_PID="$(_pane_field "$W_CLAUDE" '#{pane_pid}')"
  CLAUDISH_PID="$(_find_desc_matching "$CLAUDISH_PANE_PID" "$FIX/claudish" || true)"
  CLAUDE_PID="$(_find_desc_matching "$CLAUDE_PANE_PID" "$BIN/claude" || true)"
  [ -n "${CLAUDISH_PID:-}" ] && [ -n "${CLAUDE_PID:-}" ] && break
  sleep 0.3
done

echo "[0] PREMISE: the fake trees really have the shapes the contract cares about"
if [ -n "${CLAUDISH_PID:-}" ]; then
  ok "claudish process is live ($CLAUDISH_PID: $(_pid_cmd "$CLAUDISH_PID"))"
else
  no "claudish process is live" "no descendant of $CLAUDISH_PANE_PID matches $FIX/claudish"
fi
if [ -n "${CLAUDE_PID:-}" ]; then
  CLAUDE_PPID="$(ps -p "$CLAUDE_PID" -o ppid= 2>/dev/null | tr -d ' ')"
  if [ "$CLAUDE_PPID" != "$CLAUDE_PANE_PID" ]; then
    ok "claude is a GRANDCHILD (pane $CLAUDE_PANE_PID -> $CLAUDE_PPID -> $CLAUDE_PID)"
  else
    no "claude is a GRANDCHILD" "claude $CLAUDE_PID is a direct child of the pane"
  fi
else
  no "claude process is live" "no descendant of $CLAUDE_PANE_PID matches $BIN/claude"
fi
if [ "$fail" -ne 0 ]; then
  echo ""; echo "  Results: $pass passed, $fail failed (premise not established)"; exit 1
fi

SID_CLAUDISH="aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
SID_CLAUDE="bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"

# ── Snapshot rows built from the LIVE coordinates ────────────────────────────
# Field layout resurrect writes (and pre_save enriches):
#  1 pane  2 session  3 window_index  4 window_active  5 :window_flags
#  6 pane_index  7 title  8 :dir  9 pane_active  10 cmd  11 :full_command
#  12.. optional sentinel-prefixed columns
_row() { # <window index> <cmd> <full_command>
  local wi="$1" cmd="$2" full="$3" p t d
  p="$(_pane_field "$wi" '#{pane_index}')"
  t="$(_pane_field "$wi" '#{pane_title}')"
  d="$(_pane_field "$wi" '#{pane_current_path}')"
  printf 'pane\twork\t%s\t1\t:*\t%s\t%s\t:%s\t1\t%s\t:%s\n' "$wi" "$p" "$t" "$d" "$cmd" "$full"
}

CLAUDISH_FULL="$BIN/node $FIX/claudish $CLAUDISH_ARGS"
CLAUDE_FULL="$BIN/claude $FIX/loop.sh"

_enrich() { PATH="$SHIM:$PATH" TMUX_CMD="$TMUX_CMD_STR" bash "$PRE_SAVE" "$SNAP" >/dev/null 2>&1; }

# Row helpers that read the ENRICHED text back.
_row_for_window() { awk -F'\t' -v w="$1" '$1=="pane" && $3==w {print; exit}' "$SNAP"; }
_tag_value() { # <row> <tag>  -> value of the tagged field, by TAG not by position
  printf '%s\n' "$1" | awk -F'\t' -v tag="$2" '
    { for (i=1; i<=NF; i++) if (index($i, tag) == 1) { print substr($i, length(tag)+1); exit } }'
}
_has_tag() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null || printf '%s' "$1" | base64 -D 2>/dev/null; }

# ── 1. THE REGRESSION: empty typed-command, non-empty replay ─────────────────
# The sidmap row has a SID and replay flags but NO typed command (no launch
# file). Contract §3.5: emit ;CLAUDISH_REPLAY= and NO ;CLAUDE_CMD= — never an
# empty column between them.
echo ""
echo "[1] EMPTY MIDDLE COLUMN: replay is emitted, the typed-command column is absent (not empty)"
rm -f "$PD/by-pid/"*.session-id "$LD"/*
echo "$SID_CLAUDISH" > "$PD/by-pid/$CLAUDISH_PID.session-id"
_row "$W_CLAUDISH" node "$CLAUDISH_FULL" > "$SNAP"
_enrich
R1="$(_row_for_window "$W_CLAUDISH")"
printf '    row: %s\n' "$R1"

assert_eq "SID is embedded" "$(_tag_value "$R1" ';CLAUDE_SID=')" "$SID_CLAUDISH"
if _has_tag "$R1" ';CLAUDISH_REPLAY='; then ok "replay column present"
else no "replay column present" "row carries no ;CLAUDISH_REPLAY="; fi
assert_hasnt "typed-command column ABSENT (not emitted empty)" "$R1" ';CLAUDE_CMD='

REPLAY1="$(_tag_value "$R1" ';CLAUDISH_REPLAY=')"
assert_has "replay carries the model flag"  "$REPLAY1" "--model cx@gpt-5.6-sol"
assert_has "replay carries the -d flag"     "$REPLAY1" "-d"

# (a) No empty TAB-separated field anywhere — FR6.2, asserted on the raw bytes.
if printf '%s' "$R1" | grep -q "$(printf '\t\t')"; then
  no "no empty field in the row" "row contains two consecutive TABs"
else ok "no empty field in the row (no consecutive TABs)"; fi
case "$R1" in *"$(printf '\t')") no "no trailing empty field" "row ends with a TAB" ;;
  *) ok "no trailing empty field" ;; esac

# (b) Every optional column is sentinel-prefixed, so position never matters.
UNTAGGED="$(printf '%s\n' "$R1" | awk -F'\t' '{n=0; for (i=12; i<=NF; i++) if (substr($i,1,1) != ";") n++; print n}')"
assert_eq "every optional column is sentinel-prefixed" "$UNTAGGED" "0"

# (c) THE COLLAPSE ITSELF. A positional reader (resurrect's extra1..extra3) must
#     not be able to mistake the replay flags for the typed command. With the
#     empty column emitted, extra2 WOULD be the replay value under the CMD name;
#     with it omitted, extra2 is self-describing. Assert the reader's own view.
IFS=$'\t' read -r f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 extra1 extra2 extra3 <<EOF
$R1
EOF
assert_eq "positional extra1 is the SID column"        "${extra1%%=*}" ";CLAUDE_SID"
assert_eq "positional extra2 is the REPLAY column"     "${extra2%%=*}" ";CLAUDISH_REPLAY"
assert_eq "positional extra3 is empty (only 2 extras)" "${extra3:-}" ""
# The payload must never be readable as the typed command under any reading.
assert_hasnt "replay payload never appears under ;CLAUDE_CMD=" "$R1" ";CLAUDE_CMD=$REPLAY1"

# (d) Demonstrate the hazard is real, so the assertions above are not vacuous:
#     the SAME payload written with an empty middle column collapses on read.
BUGGY="$(printf 'pane\twork\t9\t1\t:*\t1\tt\t:/tmp\t1\tnode\t:node x\t;CLAUDE_SID=%s\t\t;CLAUDISH_REPLAY=%s' "$SID_CLAUDISH" "$REPLAY1")"
IFS=$'\t' read -r g1 g2 g3 g4 g5 g6 g7 g8 g9 g10 g11 gx1 gx2 gx3 <<EOF
$BUGGY
EOF
assert_eq "control: an empty middle column DOES collapse into extra2" \
  "${gx2%%=*}" ";CLAUDISH_REPLAY"
if [ -z "${gx3:-}" ]; then
  ok "control: the third slot is lost entirely when a column is empty"
else
  no "control: the third slot is lost entirely when a column is empty" "gx3=[$gx3]"
fi

# ── 2. All four present/absent combinations round-trip by TAG ────────────────
echo ""
echo "[2] COMBINATION MATRIX: each optional column is recovered by tag, never by position"

TYPED='c --worktree qr --name "My Session"'
TYPED_B64="$(printf '%s' "$TYPED" | base64 | tr -d '\n')"

# 2a. SID + typed command + replay (all three present).
rm -f "$PD/by-pid/"*.session-id "$LD"/*
echo "$SID_CLAUDISH" > "$PD/by-pid/$CLAUDISH_PID.session-id"
CLAUDISH_PANE_ID="$(_pane_field "$W_CLAUDISH" '#{pane_id}')"
printf '%s\n' "$TYPED" > "$LD/${CLAUDISH_PANE_ID#%}"
_row "$W_CLAUDISH" node "$CLAUDISH_FULL" > "$SNAP"
_enrich
R2="$(_row_for_window "$W_CLAUDISH")"
printf '    row: %s\n' "$R2"
assert_eq "2a SID by tag"    "$(_tag_value "$R2" ';CLAUDE_SID=')" "$SID_CLAUDISH"
assert_eq "2a typed cmd decodes verbatim" "$(_b64d "$(_tag_value "$R2" ';CLAUDE_CMD=')")" "$TYPED"
assert_has "2a replay by tag" "$(_tag_value "$R2" ';CLAUDISH_REPLAY=')" "--model cx@gpt-5.6-sol"
if printf '%s' "$R2" | grep -q "$(printf '\t\t')"; then
  no "2a no empty field" "consecutive TABs"; else ok "2a no empty field"; fi

# 2b. SID + typed command, no replay (a plain claude pane behind op).
rm -f "$PD/by-pid/"*.session-id "$LD"/*
echo "$SID_CLAUDE" > "$PD/by-pid/$CLAUDE_PID.session-id"
CLAUDE_PANE_ID="$(_pane_field "$W_CLAUDE" '#{pane_id}')"
printf '%s\n' "$TYPED" > "$LD/${CLAUDE_PANE_ID#%}"
_row "$W_CLAUDE" op "$CLAUDE_FULL" > "$SNAP"
_enrich
R3="$(_row_for_window "$W_CLAUDE")"
printf '    row: %s\n' "$R3"
assert_eq "2b SID by tag"  "$(_tag_value "$R3" ';CLAUDE_SID=')" "$SID_CLAUDE"
assert_eq "2b typed cmd decodes verbatim" "$(_b64d "$(_tag_value "$R3" ';CLAUDE_CMD=')")" "$TYPED"
assert_hasnt "2b replay column ABSENT (not emitted empty)" "$R3" ';CLAUDISH_REPLAY='
if printf '%s' "$R3" | grep -q "$(printf '\t\t')"; then
  no "2b no empty field" "consecutive TABs"; else ok "2b no empty field"; fi
IFS=$'\t' read -r h1 h2 h3 h4 h5 h6 h7 h8 h9 h10 h11 hx1 hx2 hx3 <<EOF
$R3
EOF
assert_eq "2b positional extra1 is the SID column" "${hx1%%=*}" ";CLAUDE_SID"
assert_eq "2b positional extra2 is the CMD column" "${hx2%%=*}" ";CLAUDE_CMD"

# 2c. SID only.
rm -f "$PD/by-pid/"*.session-id "$LD"/*
echo "$SID_CLAUDE" > "$PD/by-pid/$CLAUDE_PID.session-id"
_row "$W_CLAUDE" op "$CLAUDE_FULL" > "$SNAP"
_enrich
R4="$(_row_for_window "$W_CLAUDE")"
printf '    row: %s\n' "$R4"
assert_eq "2c SID by tag" "$(_tag_value "$R4" ';CLAUDE_SID=')" "$SID_CLAUDE"
assert_hasnt "2c no typed-command column"  "$R4" ';CLAUDE_CMD='
assert_hasnt "2c no replay column"         "$R4" ';CLAUDISH_REPLAY='
NF4="$(printf '%s\n' "$R4" | awk -F'\t' '{print NF}')"
assert_eq "2c exactly 12 fields (11 + one tagged extra)" "$NF4" "12"

# 2d. Nothing at all (a plain shell pane) — no extras, and still no empty field.
rm -f "$PD/by-pid/"*.session-id "$LD"/*
_row "$W_SHELL" sh "sh -c while :; do sleep 5; done" > "$SNAP"
_enrich
R5="$(_row_for_window "$W_SHELL")"
printf '    row: %s\n' "$R5"
assert_hasnt "2d no SID column"            "$R5" ';CLAUDE_SID='
assert_hasnt "2d no typed-command column"  "$R5" ';CLAUDE_CMD='
assert_hasnt "2d no replay column"         "$R5" ';CLAUDISH_REPLAY='
NF5="$(printf '%s\n' "$R5" | awk -F'\t' '{print NF}')"
assert_eq "2d exactly 11 fields (no extras)" "$NF5" "11"

# ── 3. Stability: a second save assigns the same fields ──────────────────────
echo ""
echo "[3] STABILITY: enriching twice does not shift a column"
rm -f "$PD/by-pid/"*.session-id "$LD"/*
echo "$SID_CLAUDISH" > "$PD/by-pid/$CLAUDISH_PID.session-id"
_row "$W_CLAUDISH" node "$CLAUDISH_FULL" > "$SNAP"
_enrich
FIRST="$(_row_for_window "$W_CLAUDISH")"
_row "$W_CLAUDISH" node "$CLAUDISH_FULL" > "$SNAP"
_enrich
SECOND="$(_row_for_window "$W_CLAUDISH")"
assert_eq "identical field assignment on a second save" "$SECOND" "$FIRST"

# Enriching an ALREADY-enriched row must not duplicate or shift columns either.
_enrich
THIRD="$(_row_for_window "$W_CLAUDISH")"
assert_eq "re-enriching an enriched row is a fixed point" "$THIRD" "$FIRST"
assert_eq "SID appears exactly once in the row" \
  "$(printf '%s\n' "$THIRD" | grep -o ';CLAUDE_SID=' | wc -l | tr -d ' ')" "1"

# ── 4. No token may leak into a tagged column ────────────────────────────────
echo ""
echo "[4] TOKEN HYGIENE: only a real uuid is ever written into ;CLAUDE_SID="
BAD="$(printf '%s\n' "$THIRD" | grep -o ';CLAUDE_SID=[^	]*' | grep -cv ';CLAUDE_SID=[0-9a-f-]\{36\}$' | tr -d ' ')"
assert_eq "no non-uuid value in the SID column" "$BAD" "0"

# ── 5. END TO END: the emitted assignment must produce the right relaunch ────
# A column can be present and still be assigned to the wrong reader slot. The
# only proof that the assignment is correct is what the consumer does with it.
echo ""
echo "[5] CONSUMER: the enriched row relaunches through claudish, not bare claude"
# post_restore only arms panes that look like restored shells, so replay the
# enriched EXTRAS onto the parked-shell pane's own coordinates.
EXTRAS="$(printf '%s\n' "$FIRST" | awk -F'\t' '{s=""; for (i=12; i<=NF; i++) s = s "\t" $i; print s}')"
SP_IDX="$(_pane_field "$W_SHELL" '#{pane_index}')"
SP_ID="$(_pane_field "$W_SHELL" '#{pane_id}')"
SP_CWD="$(_pane_field "$W_SHELL" '#{pane_current_path}')"
_t select-pane -t "$SP_ID" -T "replay-target" >/dev/null
printf 'pane\twork\t%s\t1\t:*\t%s\treplay-target\t:%s\t1\tnode\t:%s%s\n' \
  "$W_SHELL" "$SP_IDX" "$SP_CWD" "$CLAUDISH_FULL" "$EXTRAS" > "$SNAP"
rm -f "$QD"/*
TMUX_CMD="$TMUX_CMD_STR" RESURRECT_FILE="$SNAP" bash "$RESTORE" >/dev/null 2>&1
PENDING="$(cat "$QD/${SP_ID#%}" 2>/dev/null)"
printf '    pending: %s\n' "$PENDING"
assert_has    "relaunch goes through claudish"        "$PENDING" "claudish "
assert_has    "recorded model flag survives"          "$PENDING" "--model cx@gpt-5.6-sol"
assert_has    "recorded -d flag survives"             "$PENDING" "-d"
assert_has    "session id is resumed"                 "$PENDING" "--resume $SID_CLAUDISH"
assert_hasnt  "never downgraded to a bare claude resume" "$PENDING" "claude --resume"
# The typed-command slot was ABSENT in this row; the replay flags must not have
# been executed as if they were a typed launcher.
assert_hasnt  "replay flags were not run as the launcher" "$PENDING" "--model cx@gpt-5.6-sol --model"

echo ""
echo "=================================================================="
echo "  Results: $pass passed, $fail failed"
echo "=================================================================="
[ "$fail" -eq 0 ]
