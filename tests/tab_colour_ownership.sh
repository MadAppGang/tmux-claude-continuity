#!/usr/bin/env bash
# tab_colour_ownership.sh — cc_tab_reconcile.sh: ownership, liveness,
# precedence, the name gate, and idempotence.
#
# Runs the REAL scripts/cc_tab_reconcile.sh against an ISOLATED tmux server with
# fixture session records, and asserts on the window options it wrote.
#
# ── SAFETY (read before editing) ─────────────────────────────────────────────
# A plain `tmux -L x new-session` SOURCES ~/.tmux.conf, whose continuum
# auto-restore then rebuilds the user's entire real estate inside the test
# server — hundreds of processes. A suite run on 2026-08-17 ended with the real
# server gone: 16 sessions, 44 windows, 71 panes. tests/lib/resurrect_guard.sh
# does NOT prevent that; it guards resurrect DIRECTORIES only. Every test file
# must carry its own server isolation, and this one does:
#   * `-f /dev/null` on EVERY tmux invocation (asserted below, not assumed)
#   * a unique `-L` socket label, refused if it is empty or `default`
#   * the session records the reconciler reads are redirected with
#     CC_SESSIONS_DIR, and the TRANSCRIPTS it resolves colours from are
#     redirected with CC_PROJECTS_DIR, so neither ~/.claude/sessions nor
#     ~/.claude/projects is read or written
#   * the log and the Adapter's stamp dir are redirected under /tmp
#   * teardown kills our sessions, our server, and our fixture processes
# Nothing here ever runs `tmux` without `-L "$SOCKET" -f /dev/null`.
#
# ── WHAT THE FIXTURE PROCESSES ARE ───────────────────────────────────────────
# A record is only live if `kill -0 <pid>` succeeds, so the fixtures need real
# pids. They are `sleep` processes this test owns and kills. They do NOT run in
# the panes — the reconciler never looks at what a pane is running, only at
# whether the pane id in the record still exists.
#
# Usage: bash tests/tab_colour_ownership.sh   (exit 0 = pass)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECONCILE="$ROOT/scripts/cc_tab_reconcile.sh"
[ -x "$RECONCILE" ] || { echo "ABORT: $RECONCILE is not executable"; exit 1; }

# The resurrect guard costs nothing here (this test triggers no save) and keeps
# the file consistent with the rest of the suite if one is ever added.
. "$ROOT/tests/lib/resurrect_guard.sh" || { echo "ABORT: resurrect_guard missing"; exit 1; }
cc_register_test_session tabtest

SOCKET="cctab$$"
TMPROOT="/tmp/cctab-$$"
SESSDIR="$TMPROOT/sessions"
LOG="$TMPROOT/cc.log"
STAMP="$TMPROOT/stamp"
# The colour now comes out of a session TRANSCRIPT, so this file needs a fake
# ~/.claude/projects. It is redirected, never the user's real one: CC_PROJECTS_DIR
# and CC_COLOUR_CACHE_DIR are exported into every _reconcile call below, and
# nothing here reads or writes under $HOME/.claude.
PROJDIR="$TMPROOT/projects"
CACHE="$TMPROOT/scancache"
WD="$TMPROOT/wd"
# The slug rule the library uses as its fast path: every non-alphanumeric byte
# becomes a dash. It only has to be right for the fixture, because the library
# falls back to a glob when the computed path does not exist — which this test
# exercises from the other direction in tab_colour_resolve.sh.
SLUG=""

case "$SOCKET" in default|"") echo "ABORT: unsafe socket label"; exit 1 ;; esac
case "$TMPROOT" in /tmp/*) ;; *) echo "ABORT: TMPROOT is not under /tmp"; exit 1 ;; esac

TMUX_INVOKE="tmux -L $SOCKET -f /dev/null"
case "$TMUX_INVOKE" in
  *"-f /dev/null"*) ;;
  *) echo "ABORT: the test tmux invocation has no -f /dev/null"; exit 1 ;;
esac

_t() { tmux -L "$SOCKET" -f /dev/null "$@"; }

FAKE_PIDS=""
cleanup() {
  for s in $(_t list-sessions -F '#{session_name}' 2>/dev/null); do
    _t kill-session -t "$s" 2>/dev/null
  done
  # Only a server bound to OUR socket label. $2 must literally be tmux, else
  # this awk matches its own `-L <socket>` command line and self-kills.
  for p in $(ps -Ao pid,command= | awk -v s="-L $SOCKET" '$2 ~ /(^|\/)tmux$/ && index($0,s){print $1}'); do
    kill "$p" 2>/dev/null
  done
  for p in $FAKE_PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$TMPROOT"
}
trap 'cleanup; cc_warn_on_resurrect_leak || exit 1' EXIT INT TERM HUP

mkdir -p "$SESSDIR" "$STAMP" "$PROJDIR" "$CACHE" "$WD" || exit 1
SLUG="$(printf '%s' "$WD" | sed 's/[^A-Za-z0-9]/-/g')"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
is() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$2], want [$3]"; fi
}

# ── Fixtures ─────────────────────────────────────────────────────────────────
# NEVER wrap these in $( ). A command substitution blocks until every writer of
# its pipe closes it, and a backgrounded `sleep 900` inherits that pipe — so
# `p="$(_spawn_fake)"` hangs the test for fifteen minutes AND leaves the fixture
# process orphaned outside FAKE_PIDS, where teardown cannot reach it. Both
# happened on the first run of this file. They set a global instead, and the
# fixture's own fds are redirected so it never holds a pipe open.
FAKE_PID=""
_spawn_fake() {
  sleep 900 >/dev/null 2>&1 &
  FAKE_PID=$!
  FAKE_PIDS="$FAKE_PIDS $FAKE_PID"
}

# A pid that is certainly NOT alive: started, exited, and reaped.
DEAD_PID=""
_make_dead_pid() {
  sleep 0 >/dev/null 2>&1 &
  DEAD_PID=$!
  wait "$DEAD_PID" 2>/dev/null
}

# _sid <pid> — a UUID-SHAPED session id, derived from the pid so it is stable
# across calls. The shape is not decoration: cc_colour_transcript refuses a
# session id outside the UUID charset before it can reach the filesystem, so a
# fixture id like "sid-1234" would be rejected and every colour here would be a
# vacuous "".
_sid() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }

# _rec <pid> <window-id> <pane-id> <name> <nameSource> [<colour>]
# Writes ~/.claude/sessions/<pid>.json in the shape verified live:
#   {"pid":…,"sessionId":…,"cwd":…,"tmux":"<sess>:@<win>.%<pane>","name":…,
#    "nameSource":"user|derived|auto","status":…,"updatedAt":…}
#
# THE COLOUR IS NOT IN THIS FILE. The session record has never carried one; the
# colour is an `agent-color` record in the session TRANSCRIPT. So the optional
# sixth argument writes a fixture transcript under $PROJDIR instead, and
# omitting it leaves the session with NO transcript record at all — which is the
# common case: 2,961 of this machine's 2,991 real transcripts have none.
_rec() {
  local pid="$1" sid tdir
  sid="$(_sid "$pid")"
  printf '{"pid":%s,"sessionId":"%s","cwd":"%s","tmux":"tabtest:%s.%s","name":"%s","nameSource":"%s","status":"idle","updatedAt":1}\n' \
    "$pid" "$sid" "$WD" "$2" "$3" "$4" "$5" > "$SESSDIR/$pid.json"

  tdir="$PROJDIR/$SLUG"
  mkdir -p "$tdir"
  : > "$tdir/$sid.jsonl"
  printf '{"type":"user","cwd":"%s","message":{"role":"user","content":"hello"}}\n' "$WD" >> "$tdir/$sid.jsonl"
  if [ -n "${6:-}" ]; then
    printf '{"type":"agent-color","agentColor":"%s","sessionId":"%s"}\n' "$6" "$sid" >> "$tdir/$sid.jsonl"
  fi
}

_clear_records() { rm -f "$SESSDIR"/*.json; rm -rf "$PROJDIR"; mkdir -p "$PROJDIR"; }

_clear_opts() {
  local w
  for w in $(_t list-windows -a -F '#{window_id}'); do
    _t set -wu -t "$w" @cc_colour 2>/dev/null
    _t set -wu -t "$w" @cc_colour_pin 2>/dev/null
    _t set -wu -t "$w" @cc_name 2>/dev/null
  done
}

_reconcile() {
  CC_SESSIONS_DIR="$SESSDIR" CC_LOG_FILE="$LOG" CC_COLOUR_STAMP_DIR="$STAMP" \
  CC_PROJECTS_DIR="$PROJDIR" CC_COLOUR_CACHE_DIR="$CACHE" \
  TMUX_CMD="$TMUX_INVOKE" bash "$RECONCILE" "$@"
}

_wopt() { _t show -wqv -t "$1" "$2" 2>/dev/null; }
_pane_at() { _t list-panes -t "$1" -F '#{pane_index} #{pane_id}' | awk -v i="$2" '$1 == i { print $2; exit }'; }
_state() { _t list-windows -a -F '#{window_id}|#{@cc_colour}|#{@cc_colour_pin}|#{@cc_name}' | sort; }
_runs_logged() { grep -c 'cc_tab_reconcile:' "$LOG" 2>/dev/null || true; }

echo "=== cc_tab_reconcile.sh — ownership, liveness, precedence, names ==="

# ── Server ───────────────────────────────────────────────────────────────────
# base-index / pane-base-index are 1, reproducing this machine's real layout:
# pane_index 0 does not occur, so a reconciler that hardcoded 0 would colour
# nothing — which is the mistake this fixture exists to catch.
#
# `start-server` on its own is not enough: a tmux server with zero sessions
# exits immediately, so the options set against it evaporate ("no server running"
# on the very next command). The session is created FIRST, the options set on
# the live server, and the windows under test created afterwards; the seed
# window that predates the options is then dropped.
_t new-session -d -s tabtest -x 80 -y 24
_t set -g base-index 1
_t set -g pane-base-index 1
SEED="$(_t list-windows -a -F '#{window_id}' | sed -n 1p)"
_t new-window -t tabtest
_t new-window -t tabtest
_t kill-window -t "$SEED"

nsess="$(_t list-sessions -F '#{session_name}' 2>/dev/null | wc -l | tr -d ' ')"
is "the test server holds exactly ONE session (isolation)" "$nsess" "1"

WA="$(_t list-windows -a -F '#{window_id}' | sed -n 1p)"
WB="$(_t list-windows -a -F '#{window_id}' | sed -n 2p)"
[ -n "$WA" ] && [ -n "$WB" ] || { echo "ABORT: could not create two windows"; exit 1; }
nwin="$(_t list-windows -a -F '#{window_id}' | wc -l | tr -d ' ')"
is "exactly two windows under test" "$nwin" "2"

_t split-window -t "$WA" -d 2>/dev/null
_t split-window -t "$WA" -d 2>/dev/null
idxs="$(_t list-panes -t "$WA" -F '#{pane_index}' | tr '\n' ' ')"
is "window A has three panes at indices 1 2 3 (NOT 0)" "$(printf '%s' "$idxs" | sed 's/ *$//')" "1 2 3"

PA1="$(_pane_at "$WA" 1)"; PA2="$(_pane_at "$WA" 2)"; PA3="$(_pane_at "$WA" 3)"
PB1="$(_pane_at "$WB" 1)"

# ── 1. Ownership: three Claude sessions in ONE window ────────────────────────
# claudish:@8 has exactly this shape on the live machine right now.
#
# The pids are allocated so that the OWNER has the HIGHEST one: the session
# files are globbed in name order, so if ownership ever fell out of file order
# instead of pane_index this test would fail rather than pass by luck.
echo ""
echo "1. ownership — three Claude sessions in one window"
_spawn_fake; P_HI="$FAKE_PID"
_spawn_fake; P_MID="$FAKE_PID"
_spawn_fake; P_LO="$FAKE_PID"
# sort the three so the lowest-index pane provably gets the largest pid
PIDS_SORTED="$(printf '%s\n%s\n%s\n' "$P_HI" "$P_MID" "$P_LO" | sort -n)"
p_small="$(printf '%s' "$PIDS_SORTED" | sed -n 1p)"
p_mid="$(printf '%s' "$PIDS_SORTED" | sed -n 2p)"
p_big="$(printf '%s' "$PIDS_SORTED" | sed -n 3p)"

_clear_records; _clear_opts
_rec "$p_big" "$WA" "$PA1" "owner-name"  user green
_rec "$p_mid" "$WA" "$PA2" "second-name" user red
_rec "$p_small" "$WA" "$PA3" "third-name" user blue
_reconcile --all
is "the LOWEST pane_index owns the tab, not the lowest pid" "$(_wopt "$WA" @cc_colour)" "green"

_t set -g @cc_tab_name_source session
_reconcile --all
is "the owner's NAME is the one written" "$(_wopt "$WA" @cc_name)" "owner-name"
_t set -gu @cc_tab_name_source

# ── 2. Ownership transfers when the owner's pane closes ──────────────────────
# Not special-cased anywhere: it falls out of recomputing from scratch, which is
# the reason the reconciler is written that way.
echo ""
echo "2. ownership transfer"
_t kill-pane -t "$PA1" 2>/dev/null
_reconcile --all
is "killing the owner's pane transfers the tab to the next lowest index" \
   "$(_wopt "$WA" @cc_colour)" "red"

_t kill-pane -t "$PA2" 2>/dev/null
_reconcile --all
is "and again, to the last remaining Claude in the window" \
   "$(_wopt "$WA" @cc_colour)" "blue"

_clear_records
_reconcile --all
is "a window that lost its LAST Claude session is cleared to the default" \
   "$(_wopt "$WA" @cc_colour)" ""

# Rebuild the three panes for the rest of the file.
_t split-window -t "$WA" -d 2>/dev/null
_t split-window -t "$WA" -d 2>/dev/null
PA1="$(_pane_at "$WA" 1)"; PA2="$(_pane_at "$WA" 2)"; PA3="$(_pane_at "$WA" 3)"

# ── 3. Liveness — a stale record must never paint a tab ──────────────────────
echo ""
echo "3. liveness"
_clear_records; _clear_opts
_make_dead_pid; DEADPID="$DEAD_PID"
_rec "$DEADPID" "$WA" "$PA1" "ghost" user green
_reconcile --all
is "a record whose PID is DEAD paints nothing" "$(_wopt "$WA" @cc_colour)" ""

_clear_records; _clear_opts
_spawn_fake; P_LIVE="$FAKE_PID"
_rec "$P_LIVE" "$WA" "%99999" "ghost-pane" user green
_reconcile --all
is "a record whose PANE no longer exists paints nothing" "$(_wopt "$WA" @cc_colour)" ""

_clear_records; _clear_opts
_rec "$DEADPID" "$WA" "$PA1" "ghost" user green
_spawn_fake; P_REAL="$FAKE_PID"
_rec "$P_REAL" "$WA" "$PA2" "real" user pink
_reconcile --all
is "a dead record at a LOWER index does not out-rank a live one above it" \
   "$(_wopt "$WA" @cc_colour)" "pink"

# ── 4. Precedence, and the case that is live TODAY ───────────────────────────
# A session that never ran `/color` has NO agent-color record in its transcript
# — 2,961 of this machine's 2,991 transcripts, and 29 of its 33 live sessions.
# Those all normalise to "" — NO OPINION — so a manual pin must survive every
# reconcile, for ever. This is the single most important assertion in the file,
# and it got MORE important, not less, when the colour turned out to be
# readable: the common case is still "the session says nothing".
echo ""
echo "4. precedence — @cc_colour_pin > owner's colour > default"
_clear_records; _clear_opts
_spawn_fake; P_NC="$FAKE_PID"
_rec "$P_NC" "$WA" "$PA1" "no-colour-field" user     # transcript, NO agent-color record
_t set -w -t "$WA" @cc_colour_pin purple
_reconcile --all
is "ABSENT agent-color record leaves a manual pin standing" "$(_wopt "$WA" @cc_colour)" "purple"

_reconcile --all; _reconcile --all; _reconcile --all
is "and it is still standing after four reconciles" "$(_wopt "$WA" @cc_colour)" "purple"

_clear_opts
_reconcile --all
is "with no pin and no agent-color record the tab stays uncoloured" "$(_wopt "$WA" @cc_colour)" ""

_clear_records
_rec "$P_NC" "$WA" "$PA1" "has-colour" user green
_t set -w -t "$WA" @cc_colour_pin orange
_reconcile --all
is "a pin OUT-RANKS the owner's own colour" "$(_wopt "$WA" @cc_colour)" "orange"

_t set -wu -t "$WA" @cc_colour_pin
_reconcile --all
is "clearing the pin hands control back to the owner's colour" "$(_wopt "$WA" @cc_colour)" "green"

_clear_records
_rec "$P_NC" "$WA" "$PA1" "opaque" user '#a6e3a1'
_reconcile --all
is "an OPAQUE colour value is a non-opinion, not a wrong colour" "$(_wopt "$WA" @cc_colour)" ""

# ── 5. Idempotence ───────────────────────────────────────────────────────────
# Delivery is at-least-once: pane-exited, after-kill-pane, SessionStart and Stop
# can all fire for one event. Five runs must equal one run — and runs 2..5 must
# issue no writes at all, which is what keeps this cheap on every Claude turn.
echo ""
echo "5. idempotence"
_clear_records; _clear_opts
_spawn_fake; P_I1="$FAKE_PID"
_spawn_fake; P_I2="$FAKE_PID"
_rec "$P_I1" "$WA" "$PA1" "alpha" user green
_rec "$P_I2" "$WB" "$PB1" "beta"  user blue
_t set -g @cc_tab_name_source session

_reconcile --all
S1="$(_state)"
runs_before="$(_runs_logged)"
_reconcile --all; S2="$(_state)"
_reconcile --all; S3="$(_state)"
_reconcile --all; S4="$(_state)"
_reconcile --all; S5="$(_state)"
runs_after="$(_runs_logged)"

if [ "$S1" = "$S2" ] && [ "$S2" = "$S3" ] && [ "$S3" = "$S4" ] && [ "$S4" = "$S5" ]; then
  ok "five consecutive runs leave IDENTICAL option state"
else
  no "five consecutive runs leave IDENTICAL option state" \
     "run1=[$S1] run2=[$S2] run3=[$S3] run4=[$S4] run5=[$S5]"
fi
is "runs 2..5 wrote NOTHING (no log line means no option changed)" \
   "${runs_before:-0}" "${runs_after:-0}"
_t set -gu @cc_tab_name_source

# ── 6. Scope ─────────────────────────────────────────────────────────────────
echo ""
echo "6. scope — single window, pane id, and window isolation"
_clear_opts
_reconcile "$WA"
is "single-window mode paints the named window" "$(_wopt "$WA" @cc_colour)" "green"
is "single-window mode leaves every OTHER window untouched" "$(_wopt "$WB" @cc_colour)" ""
_reconcile "$WB"
is "the other window paints when it is its turn" "$(_wopt "$WB" @cc_colour)" "blue"

_clear_opts
_reconcile "$PA1"
is "a PANE id resolves to its own window (what the Claude hooks pass)" \
   "$(_wopt "$WA" @cc_colour)" "green"
is "and still touches nothing else" "$(_wopt "$WB" @cc_colour)" ""

_clear_opts
_reconcile "%99999"
is "a pane id that no longer exists is a silent no-op" "$(_wopt "$WA" @cc_colour)" ""

# ── 7. The name gate — three-valued, defaulting to `user` ────────────────────
# Of 33 live sessions, 21 are `derived`, 9 are `auto` and only 3 are `user`.
# Existing window names are hand-set and meaningful ("deploy magento2"); derived
# Claude names are "dotfiles-27". Always-on would be a regression, so the
# default writes a name only when a HUMAN named the session.
echo ""
echo "7. the @cc_tab_name_source gate"
_clear_records; _clear_opts
_spawn_fake; P_N="$FAKE_PID"

_t set -gu @cc_tab_name_source
_rec "$P_N" "$WA" "$PA1" "derived-name" derived
_reconcile --all
is "DEFAULT (unset) + nameSource=derived -> no name written" "$(_wopt "$WA" @cc_name)" ""

_clear_records; _clear_opts
_rec "$P_N" "$WA" "$PA1" "auto-name" auto
_reconcile --all
is "DEFAULT + nameSource=auto -> no name (the test is ==user, never !=derived)" \
   "$(_wopt "$WA" @cc_name)" ""

_clear_records; _clear_opts
_rec "$P_N" "$WA" "$PA1" "human-name" user
_reconcile --all
is "DEFAULT + nameSource=user -> the name IS written" "$(_wopt "$WA" @cc_name)" "human-name"

_clear_opts
_t set -g @cc_tab_name_source window
_reconcile --all
is "'window' never writes a name, even for a human-named session" "$(_wopt "$WA" @cc_name)" ""

_clear_records; _clear_opts
_rec "$P_N" "$WA" "$PA1" "derived-name" derived
_t set -g @cc_tab_name_source session
_reconcile --all
is "'session' writes the name whatever nameSource says" "$(_wopt "$WA" @cc_name)" "derived-name"

# Staleness: a name written under one mode must not outlive the mode, or a tab
# keeps showing a session name that nothing is producing any more.
_t set -g @cc_tab_name_source user
_reconcile --all
is "switching back to 'user' CLEARS a name the 'session' mode had written" \
   "$(_wopt "$WA" @cc_name)" ""

_t set -g @cc_tab_name_source session
_reconcile --all
_clear_records
_reconcile --all
is "losing the last Claude session clears the name too" "$(_wopt "$WA" @cc_name)" ""
_t set -gu @cc_tab_name_source

# ── 8. The name reaches a tmux option sanitised ──────────────────────────────
# @cc_name is interpolated into window-status-format. `#` is the tmux format
# introducer, and a newline or a tab would break the option table this script
# reads back on its next run.
echo ""
echo "8. name sanitisation"
_clear_records; _clear_opts
_t set -g @cc_tab_name_source session
LONGNAME="abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789abcdefghij0123456789"
_rec "$P_N" "$WA" "$PA1" "na#me$(printf '')ok" user
_reconcile --all
got="$(_wopt "$WA" @cc_name)"
case "$got" in
  *'#'*) no "'#' is stripped before the name reaches the option" "got [$got]" ;;
  *)     ok "'#' is stripped before the name reaches the option (got [$got])" ;;
esac

_clear_records; _clear_opts
_rec "$P_N" "$WA" "$PA1" "$LONGNAME" user
_reconcile --all
got="$(_wopt "$WA" @cc_name)"
if [ "${#got}" -le 64 ] && [ -n "$got" ]; then
  ok "an over-long name is capped at 64 characters (got ${#got})"
else
  no "an over-long name is capped at 64 characters" "length ${#got}: [$got]"
fi
_t set -gu @cc_tab_name_source

# ── 9. Robustness — one unparseable record must not blank the estate ─────────
# Claude rewrites these files continuously, so a half-written one is possible.
# Under a single `jq -s` one bad file aborts the whole call, which would leave
# every tab in the estate uncoloured until the next turn.
echo ""
echo "9. a malformed session record"
_clear_records; _clear_opts
_rec "$P_N" "$WA" "$PA1" "survivor" user green
printf '{"pid":1,"tmux":"broken"' > "$SESSDIR/999999.json"    # truncated JSON
_reconcile --all
is "a truncated record is skipped and the others still paint" \
   "$(_wopt "$WA" @cc_colour)" "green"
_clear_records

# ── 10. Anti-vacuity ─────────────────────────────────────────────────────────
# Most assertions above are "the option is empty". If the reconciler were a
# no-op — wrong path, missing jq, an early exit — every one of them would pass.
echo ""
echo "10. anti-vacuity"
_clear_records; _clear_opts
_spawn_fake; P_V="$FAKE_PID"
_rec "$P_V" "$WA" "$PA1" "vacuity" user cyan
_reconcile --all
if [ "$(_wopt "$WA" @cc_colour)" = "cyan" ]; then
  ok "the reconciler demonstrably WRITES (the empty assertions are not vacuous)"
else
  no "the reconciler demonstrably WRITES" "expected cyan, got [$(_wopt "$WA" @cc_colour)]"
fi

if cc_selftest_leak_detector "$TMPROOT"; then
  ok "the resurrect leak detector is live"
else
  no "the resurrect leak detector is live" "cc_selftest_leak_detector returned non-zero"
fi

printf '\n  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
