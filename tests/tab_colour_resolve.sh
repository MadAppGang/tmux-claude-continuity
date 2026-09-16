#!/usr/bin/env bash
# tab_colour_resolve.sh — scripts/lib/cc_colour.sh, the Claude colour Adapter.
#
# It is the ONLY place in either repo that names Claude's colour schema, and the
# schema it names is REAL and validated on live sessions:
#
#     {"type":"agent-color","agentColor":"purple","sessionId":"d2e5f013-..."}
#
# last record wins, in ~/.claude/projects/<slug>/<sessionId>.jsonl.
#
# ── THE TWO ASSERTIONS THAT MATTER MOST ──────────────────────────────────────
# 1. ABSENT IS THE COMMON CASE and it must mean "no opinion", not "no colour".
#    Measured: 2,961 of 2,991 transcripts on this machine carry no agent-color
#    record at all, and 29 of 33 LIVE sessions carry none. If "" and "default"
#    were collapsed, almost every session would out-vote a colour the human
#    pinned by hand and the pin would be erased on the next Stop hook.
# 2. A SUBAGENT IS NOT A SESSION COLOUR. Spawning a real general-purpose
#    subagent left the record count unchanged (2 -> 2). The `color` key in
#    subagents/agent-*.meta.json belongs to `taskKind: in_process_teammate` —
#    a different field, in a different file, for a different feature. A
#    transcript stuffed with both must still resolve to the session's colour.
#
# ── ISOLATION ────────────────────────────────────────────────────────────────
# Every transcript read here is a FIXTURE under $TD. CC_PROJECTS_DIR,
# CC_COLOUR_CACHE_DIR and CC_COLOUR_STAMP_DIR are all redirected before the
# library is sourced, so the user's ~/.claude is never read and never written.
# No tmux server is started and no tmux command is run.
#
# Usage: bash tests/tab_colour_resolve.sh   (exit 0 = pass)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/cc_colour.sh"
[ -f "$LIB" ] || { echo "ABORT: $LIB is missing"; exit 1; }

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
# `A && ok || no` is not if-then-else (shellcheck SC2015) — it only happens to
# work here because ok() ends in a successful printf. Use an explicit helper.
is() { # <label> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "got [$2], want [$3]"; fi
}

TD="$(mktemp -d /tmp/cctabres-XXXXXX)" || exit 1
trap 'rm -rf "$TD"' EXIT INT TERM HUP

export CC_PROJECTS_DIR="$TD/projects"
export CC_COLOUR_CACHE_DIR="$TD/scancache"
export CC_COLOUR_STAMP_DIR="$TD/stamp"
export CC_LOG_FILE="$TD/cc.log"
mkdir -p "$CC_PROJECTS_DIR" || exit 1

# shellcheck source=../scripts/lib/cc_common.sh
. "$ROOT/scripts/lib/cc_common.sh"
# shellcheck source=../scripts/lib/cc_colour.sh
. "$LIB"

# Anti-vacuity guard for the whole file: if the library ever resolved against
# the real ~/.claude, every fixture assertion below could pass or fail for
# reasons that have nothing to do with the fixture.
case "$CC_PROJECTS_DIR" in
  "$TD"/*) ;;
  *) echo "ABORT: CC_PROJECTS_DIR escaped the fixture root"; exit 1 ;;
esac

# `grep -c` prints 0 AND exits 1 on no match, so the obvious `|| echo 0` form
# prints "0\n0" and every numeric comparison below becomes a syntax error.
logcount() {
  local n
  [ -f "$CC_LOG_FILE" ] || { printf '0'; return 0; }
  n="$(grep -c 'cc_colour:' "$CC_LOG_FILE" 2>/dev/null)"
  printf '%s' "${n:-0}"
}
reset_log() { : > "$CC_LOG_FILE"; rm -rf "$CC_COLOUR_STAMP_DIR"; _CC_COLOUR_SEEN=""; }
reset_cache() { rm -rf "$CC_COLOUR_CACHE_DIR"; }

# eq <label> <input> <expected> — cc_colour_normalise in isolation.
eq() {
  local label="$1" in="$2" want="$3" got
  got="$(cc_colour_normalise "$in")"
  if [ "$got" = "$want" ]; then ok "$label"
  else no "$label" "cc_colour_normalise '$in' -> '$got', expected '$want'"; fi
}

# ── Fixture builders ─────────────────────────────────────────────────────────
# slug_of <cwd> — the library's own fast-path rule, restated here so a change to
# it shows up as a failing test rather than as silently uncoloured tabs.
slug_of() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# uuid <n> — a UUID-SHAPED id. The shape is load-bearing: cc_colour_transcript
# refuses anything outside the UUID charset before it can reach the filesystem,
# so a fixture called "sid-1" would resolve to "" for the wrong reason.
uuid() { printf '%08x-0000-4000-8000-%012x' "$1" "$1"; }

# new_transcript <sid> <cwd> — create an empty transcript at the SLUG path and
# echo the file. Ordinary session traffic is added so no assertion below is
# testing an empty file.
new_transcript() {
  local sid="$1" cwd="$2" d
  d="$CC_PROJECTS_DIR/$(slug_of "$cwd")"
  mkdir -p "$d"
  {
    printf '{"type":"user","cwd":"%s","sessionId":"%s","message":{"role":"user","content":"hi"}}\n' "$cwd" "$sid"
    printf '{"type":"assistant","cwd":"%s","sessionId":"%s","message":{"role":"assistant","content":"ok"}}\n' "$cwd" "$sid"
  } > "$d/$sid.jsonl"
  printf '%s' "$d/$sid.jsonl"
}

add_colour() { # <file> <token>
  printf '{"type":"agent-color","agentColor":"%s","sessionId":"x"}\n' "$2" >> "$1"
}

pad() { # <file> <bytes-ish> — bulk traffic, to push records out of a tail window
  local f="$1" want="$2" n=0
  while [ "$n" -lt "$want" ]; do
    printf '{"type":"assistant","message":{"role":"assistant","content":"%s"}}\n' \
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >> "$f"
    n=$((n + 160))
  done
}

echo "=== cc_colour.sh — the Claude agent-color Adapter ==="

# ── A. The vocabulary round-trips ────────────────────────────────────────────
echo ""
echo "A. vocabulary"
for c in red orange yellow green cyan blue purple pink; do
  eq "'$c' is itself" "$c" "$c"
done
eq "'default' is itself"            default default
eq "uppercase is folded"            GREEN   green
eq "surrounding space is stripped"  '  Green  ' green
reset_log

# ── B. The three outcomes, held apart ────────────────────────────────────────
echo ""
echo "B. absent vs opaque vs explicitly-none"

reset_log
eq "ABSENT record -> '' (NOT 'default')" "" ""
if [ "$(logcount)" -eq 0 ]; then ok "absent record logs nothing"
else no "absent record logs nothing" "logged $(logcount) line(s)"; fi

reset_log
eq "whitespace-only is treated as absent" "   " ""
if [ "$(logcount)" -eq 0 ]; then ok "whitespace-only logs nothing"
else no "whitespace-only logs nothing" "logged $(logcount) line(s)"; fi

eq "'default' -> default"   default default
eq "'none'    -> default"   none    default
eq "'auto'    -> default"   auto    default

if [ "$(cc_colour_normalise '')" != "$(cc_colour_normalise default)" ]; then
  ok "'' and 'default' are DIFFERENT values (the pin-erasure guard)"
else
  no "'' and 'default' are DIFFERENT values (the pin-erasure guard)" \
     "both resolved to '$(cc_colour_normalise '')'"
fi

# ── C. A token we do not carry degrades to no opinion, and is logged once ────
echo ""
echo "C. an agentColor we do not understand"

for v in 'chartreuse' '#a6e3a1' '4' '{"name":"green"}'; do
  reset_log
  got="$(cc_colour_normalise "$v")"
  n="$(logcount)"
  if [ -z "$got" ] && [ "$n" -eq 1 ]; then
    ok "'$v' -> '' and exactly ONE log line"
  else
    no "'$v' -> '' and exactly ONE log line" "got '$got', $n log line(s)"
  fi
done

reset_log
cc_colour_normalise 'chartreuse' >/dev/null
if grep -q "unrecognised agentColor 'chartreuse'" "$CC_LOG_FILE" 2>/dev/null; then
  ok "the RAW value is in the log (this is how a schema change is discovered)"
else
  no "the RAW value is in the log" "log: $(cat "$CC_LOG_FILE" 2>/dev/null)"
fi

# The Stop hook runs on every turn. Without dedupe a schema change would put one
# line per live session into the log per turn.
reset_log
for _ in 1 2 3 4 5; do cc_colour_normalise 'chartreuse' >/dev/null; done
if [ "$(logcount)" -eq 1 ]; then ok "five calls with the same unknown value log ONCE"
else no "five calls with the same unknown value log ONCE" "$(logcount) line(s)"; fi

reset_log
cc_colour_normalise 'chartreuse' >/dev/null
cc_colour_normalise 'burgundy'   >/dev/null
if [ "$(logcount)" -eq 2 ]; then ok "two DIFFERENT unknown values log twice"
else no "two DIFFERENT unknown values log twice" "$(logcount) line(s)"; fi

# ── D. Aliases a future build could plausibly emit ───────────────────────────
echo ""
echo "D. aliases"
reset_log
eq "magenta -> pink"   magenta pink
eq "violet  -> purple" violet  purple
eq "teal    -> cyan"   teal    cyan
if [ "$(logcount)" -eq 0 ]; then ok "a known alias is not logged as unknown"
else no "a known alias is not logged as unknown" "$(logcount) line(s)"; fi

# ── E. The REAL schema, against fixture transcripts ──────────────────────────
echo ""
echo "E. agent-color records in a transcript"
reset_log; reset_cache

CWD="$TD/wd"
S1="$(uuid 1)"; F1="$(new_transcript "$S1" "$CWD")"
add_colour "$F1" green
is "one agent-color record resolves" "$(cc_colour_for_session "$S1" "$CWD")" "green"

# LAST WINS. Validated live: /color green then /color purple -> purple.
add_colour "$F1" red
add_colour "$F1" purple
is "LAST record wins over three" "$(cc_colour_for_session "$S1" "$CWD")" "purple"

S2="$(uuid 2)"; new_transcript "$S2" "$CWD" >/dev/null
is "a transcript with NO agent-color record -> '' (no opinion)" \
   "$(cc_colour_for_session "$S2" "$CWD")" ""
if [ "$(logcount)" -eq 0 ]; then ok "...and it is SILENT (this is ~99% of sessions)"
else no "...and it is SILENT" "$(logcount) line(s): $(cat "$CC_LOG_FILE")"; fi

S3="$(uuid 3)"; F3="$(new_transcript "$S3" "$CWD")"
add_colour "$F3" default
is "an explicit 'default' record -> 'default' (an OPINION)" \
   "$(cc_colour_for_session "$S3" "$CWD")" "default"

# The distinction, restated end to end rather than on the normaliser alone: this
# is what keeps a manual pin alive on ~99% of windows.
if [ "$(cc_colour_for_session "$S2" "$CWD")" != "$(cc_colour_for_session "$S3" "$CWD")" ]; then
  ok "absent and 'default' differ END TO END (transcript -> token)"
else
  no "absent and 'default' differ END TO END" "both '$(cc_colour_for_session "$S2" "$CWD")'"
fi

reset_log
S4="$(uuid 4)"; F4="$(new_transcript "$S4" "$CWD")"
add_colour "$F4" chartreuse
got="$(cc_colour_for_session "$S4" "$CWD")"
if [ -z "$got" ] && [ "$(logcount)" -eq 1 ]; then
  ok "an UNRECOGNISED token -> '' plus one log line (end to end)"
else
  no "an UNRECOGNISED token -> '' plus one log line" "got '$got', $(logcount) line(s)"
fi

# A pin must survive the absent case. The reconciler owns precedence, so what is
# asserted here is the input that decision is made on: an absent record is the
# EMPTY string, which is the only value the precedence rule treats as "leave the
# pin alone". tab_colour_ownership.sh drives the same case through real tmux.
reset_log
if [ -z "$(cc_colour_for_session "$S2" "$CWD")" ] && \
   [ "$(cc_colour_for_session "$S2" "$CWD")" != "default" ]; then
  ok "absent -> the exact value the pin rule needs ('' and not 'default')"
else
  no "absent -> the exact value the pin rule needs" "got '$(cc_colour_for_session "$S2" "$CWD")'"
fi

# ── F. A SUBAGENT must never be mistaken for the session colour ──────────────
# Validated live: a real general-purpose subagent left the agent-color count
# unchanged (2 -> 2). The colours that DO exist around subagents belong to
# `taskKind: in_process_teammate` and live in subagents/agent-*.meta.json — a
# different key, in a different file, which this library must never read.
echo ""
echo "F. subagents and teammates are not the session colour"
reset_log; reset_cache

S5="$(uuid 5)"; F5="$(new_transcript "$S5" "$CWD")"
cat >> "$F5" <<'SUB'
{"type":"user","isSidechain":true,"agent_type":"general-purpose","message":{"role":"user","content":"run"}}
{"type":"assistant","isSidechain":true,"agent_type":"general-purpose","team_name":"session-9","message":{"role":"assistant","content":"done"}}
{"type":"user","message":{"role":"user","content":"the teammate meta said \"color\":\"blue\" and \"type\":\"agent-color\" once"}}
SUB
is "a transcript FULL of subagent traffic and no agent-color -> ''" \
   "$(cc_colour_for_session "$S5" "$CWD")" ""

# The teammate sidecar, in the place Claude really puts it, with a colour that
# is NOT the session's. Reading it would return blue.
mkdir -p "$(dirname "$F5")/subagents"
printf '{"agentType":"general-purpose","taskKind":"in_process_teammate","teamName":"session-9","color":"blue"}\n' \
  > "$(dirname "$F5")/subagents/agent-abc.meta.json"
is "a teammate meta with a 'color' key beside the transcript is IGNORED" \
   "$(cc_colour_for_session "$S5" "$CWD")" ""

# ...and when the session DOES have a colour, the subagent noise must not
# displace it.
add_colour "$F5" orange
cat >> "$F5" <<'SUB2'
{"type":"user","isSidechain":true,"agent_type":"code-reviewer","message":{"role":"user","content":"look"}}
SUB2
is "subagent traffic AFTER the record does not displace the session colour" \
   "$(cc_colour_for_session "$S5" "$CWD")" "orange"

if [ "$(logcount)" -eq 0 ]; then ok "none of the subagent noise was logged as an unknown value"
else no "none of the subagent noise was logged" "$(logcount): $(cat "$CC_LOG_FILE")"; fi

# ── G. A malformed record must not poison the answer ─────────────────────────
# Claude appends to this file continuously, so a half-written final line is
# reachable. An earlier build of this feature let one bad record blank the whole
# result; the scanner now only ever ASSIGNS on a well-formed match.
echo ""
echo "G. malformed and truncated records"
reset_log; reset_cache

S6="$(uuid 6)"; F6="$(new_transcript "$S6" "$CWD")"
add_colour "$F6" cyan
{
  printf '{"type":"agent-color","agentColor":"pi'          # torn mid-write
  printf '\n{"type":"agent-color"}\n'                     # no agentColor key
  printf '{"type":"agent-color","agentColor":}\n'          # invalid JSON
  printf 'not json at all\n'
} >> "$F6"
is "a truncated final record does NOT blank a good one" \
   "$(cc_colour_for_session "$S6" "$CWD")" "cyan"

add_colour "$F6" pink
is "and a good record after the garbage still wins" \
   "$(cc_colour_for_session "$S6" "$CWD")" "pink"

S7="$(uuid 7)"; F7="$(new_transcript "$S7" "$CWD")"
printf '{"type":"agent-color","agentColor":"gre\n' >> "$F7"
is "a torn record with NO good record -> '' (not a guess)" \
   "$(cc_colour_for_session "$S7" "$CWD")" ""

# A user message DISCUSSING the schema is JSON-escaped, so the literal cannot
# match. Reading it would be a colour set by a sentence.
S8="$(uuid 8)"; F8="$(new_transcript "$S8" "$CWD")"
printf '{"type":"user","message":{"role":"user","content":"set {\\"type\\":\\"agent-color\\",\\"agentColor\\":\\"red\\"} please"}}\n' >> "$F8"
is "a user MESSAGE quoting the record is not a colour" \
   "$(cc_colour_for_session "$S8" "$CWD")" ""

# ── H. The tail window and the full-scan fallback agree ──────────────────────
# The tail window is the fast path (~9.8 ms, and it agreed with a full scan on
# 31/31 real transcripts that carry a record). It is a WINDOW, so a colour set
# early in a very long session falls outside it and the fallback has to find it.
echo ""
echo "H. tail window vs full scan"
reset_log; reset_cache

S9="$(uuid 9)"; F9="$(new_transcript "$S9" "$CWD")"
add_colour "$F9" yellow
pad "$F9" 60000                                   # colour now far from EOF
sz="$(wc -c < "$F9" | tr -d ' ')"

reset_cache
got_full="$(CC_COLOUR_TAIL_BYTES=$((sz + 1000)) cc_colour_for_session "$S9" "$CWD")"
reset_cache
got_tail="$(CC_COLOUR_TAIL_BYTES=2000 cc_colour_for_session "$S9" "$CWD")"
is "full scan finds a colour ${sz}B from EOF" "$got_full" "yellow"
is "a 2000-byte tail window MISSES it, then the fallback finds it" "$got_tail" "yellow"
is "the two paths agree" "$got_tail" "$got_full"

# Prove the tail window alone really would have missed it — otherwise the
# assertion above passes without the fallback ever running.
raw_tail="$(tail -c 2000 "$F9" | awk "$_CC_COLOUR_SCAN_AWK")"
is "anti-vacuity: the 2000-byte window on its own yields nothing" "$raw_tail" ""

# And with the record INSIDE the window, the tail path answers on its own.
add_colour "$F9" blue
reset_cache
is "a record inside the window is answered by the tail path" \
   "$(CC_COLOUR_TAIL_BYTES=2000 cc_colour_for_session "$S9" "$CWD")" "blue"

# The watermark cache must not invent or lose an answer: repeat calls agree.
reset_cache
a="$(CC_COLOUR_TAIL_BYTES=2000 cc_colour_for_session "$S9" "$CWD")"
b="$(CC_COLOUR_TAIL_BYTES=2000 cc_colour_for_session "$S9" "$CWD")"
c="$(CC_COLOUR_TAIL_BYTES=2000 cc_colour_for_session "$S9" "$CWD")"
if [ "$a" = "$b" ] && [ "$b" = "$c" ]; then ok "three consecutive resolves agree ($a)"
else no "three consecutive resolves agree" "[$a] [$b] [$c]"; fi

# A colour that has scrolled out of the window is REMEMBERED across calls: the
# cache exists so a transcript is never rescanned from byte 0 on every hook.
S10="$(uuid 10)"; F10="$(new_transcript "$S10" "$CWD")"
add_colour "$F10" pink
pad "$F10" 20000
reset_cache
first="$(CC_COLOUR_TAIL_BYTES=1000 cc_colour_for_session "$S10" "$CWD")"
pad "$F10" 20000                                   # the session keeps talking
second="$(CC_COLOUR_TAIL_BYTES=1000 cc_colour_for_session "$S10" "$CWD")"
is "a colour outside the window is found once..."      "$first"  "pink"
is "...and is still the answer after the file grows"   "$second" "pink"

# A truncated/replaced file must not be answered from a stale cache.
: > "$F10"
add_colour "$F10" green
is "a REPLACED transcript is not answered from the old cache" \
   "$(CC_COLOUR_TAIL_BYTES=1000 cc_colour_for_session "$S10" "$CWD")" "green"

# ── I. Locating the transcript ───────────────────────────────────────────────
# GLOB IS PRIMARY. MEASURED on this machine: the slug rule (every non-alphanumeric
# byte -> dash) reproduces the real directory for 2,828 of 2,950 transcripts —
# 95.86%, not 100%. Worktree sessions are the gap: some are filed under the
# PARENT repo's directory, some under their own path, and no cwd-derived rule
# covers both. A wrong slug is a silently uncoloured tab, so the slug is only
# ever a fast path that has to prove itself by the file existing.
echo ""
echo "I. finding the transcript"
reset_log; reset_cache

SA="$(uuid 11)"; FA="$(new_transcript "$SA" "$CWD")"
add_colour "$FA" red
is "slug fast path: the computed directory is used when the file is there" \
   "$(cc_colour_transcript "$SA" "$CWD")" "$FA"

is "the glob finds it with NO cwd at all" "$(cc_colour_transcript "$SA" "")" "$FA"
is "...and resolves the same colour" "$(cc_colour_for_session "$SA" "")" "red"

# The worktree-collapse case, reproduced exactly: cwd says the worktree, the
# transcript is filed under the parent repo. The slug misses; the glob must not.
SB="$(uuid 12)"
PARENT="$TD/repo"
WORKTREE="$TD/repo/.claude/worktrees/init"
FB="$(new_transcript "$SB" "$PARENT")"
add_colour "$FB" blue
is "WORKTREE COLLAPSE: a wrong slug falls through to the glob" \
   "$(cc_colour_transcript "$SB" "$WORKTREE")" "$FB"
is "...and the colour still resolves" "$(cc_colour_for_session "$SB" "$WORKTREE")" "blue"
if [ ! -e "$CC_PROJECTS_DIR/$(slug_of "$WORKTREE")/$SB.jsonl" ]; then
  ok "anti-vacuity: the slug path really does not exist for that cwd"
else
  no "anti-vacuity: the slug path really does not exist" "it does"
fi

# Four session ids on this machine exist in TWO project directories (a session
# resumed from another cwd). The one still being appended to is the live answer.
SC="$(uuid 13)"
FC_OLD="$(new_transcript "$SC" "$TD/old")"
add_colour "$FC_OLD" green
sleep 1
FC_NEW="$(new_transcript "$SC" "$TD/new")"
add_colour "$FC_NEW" purple
is "a session id in TWO project dirs resolves to the NEWEST file" \
   "$(cc_colour_transcript "$SC" "")" "$FC_NEW"
is "...so the colour is the live one" "$(cc_colour_for_session "$SC" "")" "purple"

is "an unknown session id -> '' (no path, no colour)" \
   "$(cc_colour_transcript "$(uuid 999)" "")" ""

# The glob guard. A session id is interpolated into a path AND into a glob, so
# anything outside the UUID charset is refused before it reaches the filesystem.
for bad in '../../etc/passwd' '*' 'a/b' '' 'sid-1'; do
  got="$(cc_colour_transcript "$bad" "$CWD")"
  if [ -z "$got" ]; then ok "a session id of '$bad' is refused outright"
  else no "a session id of '$bad' is refused outright" "got '$got'"; fi
done

if [ "$(logcount)" -eq 0 ]; then ok "none of the lookup cases logged anything"
else no "none of the lookup cases logged anything" "$(logcount): $(cat "$CC_LOG_FILE")"; fi

# ── J. The schema is named in exactly one place ──────────────────────────────
# If a second file learns the record type or the field name, the "two edits
# cover a schema change" promise in cc_colour.sh is already false.
echo ""
echo "J. the schema is named in exactly one place"
leak="$(grep -rn 'agentColor\|agent-color' "$ROOT/scripts" "$ROOT"/*.tmux 2>/dev/null \
        | grep -v '/lib/cc_colour\.sh:' || true)"
if [ -z "$leak" ]; then
  ok "no script outside lib/cc_colour.sh names the agent-color schema"
else
  no "no script outside lib/cc_colour.sh names the agent-color schema" "$leak"
fi

# ── K. Anti-vacuity ──────────────────────────────────────────────────────────
# "Nothing was logged" is worthless if the logger cannot fire at all, and
# "nothing resolved" is worthless if the scanner cannot resolve at all.
echo ""
echo "K. anti-vacuity"
reset_log
cc_colour_normalise 'definitely-not-a-colour' >/dev/null
if [ "$(logcount)" -eq 1 ]; then
  ok "the log detector fires when it should"
else
  no "the log detector fires when it should" "expected 1 line in $CC_LOG_FILE, got $(logcount)"
fi

reset_log; reset_cache
SZ="$(uuid 14)"; FZ="$(new_transcript "$SZ" "$CWD")"
is "a bare fixture transcript resolves to '' before a record is added" \
   "$(cc_colour_for_session "$SZ" "$CWD")" ""
add_colour "$FZ" green
is "...and to 'green' the moment one is" \
   "$(cc_colour_for_session "$SZ" "$CWD")" "green"

printf '\n  RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
