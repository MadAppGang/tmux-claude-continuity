#!/usr/bin/env bash
# cc_colour.sh — the ONLY place in either repo that names Claude's colour schema.
#
# Sourced, never executed. An Adapter: it implements OUR interface (a nine-token
# vocabulary the tmux formats understand) over THEIR shape (a record type in the
# session transcript). The direction is deliberate — our side owns the
# vocabulary, so whatever Claude changes never leaks past this file.
#
# ── THE REAL SCHEMA (measured on live sessions, not inferred) ────────────────
# The colour a user sets with `/color` is persisted in the SESSION TRANSCRIPT,
# `~/.claude/projects/<slug>/<sessionId>.jsonl`, as its own record type:
#
#     {"type":"agent-color","agentColor":"purple","sessionId":"d2e5f013-..."}
#
# Four properties, each validated rather than assumed:
#
#   LAST RECORD WINS.  `/color green` then `/color purple` resolves to purple.
#     A session accumulates one record per `/color`; the tail of the file is the
#     current answer.
#
#   ABSENT IS THE COMMON CASE.  A session that never ran `/color` contains ZERO
#     such records (checked on a fresh session: 35 transcript lines, 0 records).
#     Machine-wide, 30 of 2,991 transcripts carry one. So the absent path must
#     stay cheap AND silent — it is ~99% of traffic, and it must resolve to
#     "no opinion", never to "no colour".
#
#   SUBAGENTS WRITE NOTHING HERE.  Spawning a real general-purpose subagent left
#     the record count unchanged (2 -> 2). The `color` key in
#     `subagents/agent-*.meta.json` belongs to `taskKind: in_process_teammate`
#     (the teams feature) and is a DIFFERENT field in a DIFFERENT file. This
#     library never reads it, and a transcript full of subagents resolves to the
#     session's own colour or to nothing at all.
#
#   THE TOKENS MATCH OUR PALETTE.  Observed across every transcript on this
#     machine: green, red, orange, yellow, purple, pink (plus blue and cyan in
#     the binary's table, and `default`). 2,192 of 2,192 `agentColor` lines also
#     carry `"type":"agent-color"`, which is why the scanner keys on both.
#
# Two weaker sibling signals live in the same file and are deliberately NOT
# read: `"commandRun":{"command":"color","args":"green"}` (args is EMPTY for a
# bare `/color`, which assigns a random colour) and the
# `<local-command-stdout>Session color set to: green</local-command-stdout>`
# line. Neither is canonical; the `agent-color` record covers both cases,
# including bare `/color`, because Claude writes the resolved colour either way.
#
# A schema change needs exactly two edits: one to _CC_COLOUR_SCAN_AWK (where the
# record is recognised) and one to cc_colour_normalise (how a value is spelled).
# Nothing else in either repo may name a Claude colour field. The check:
#   grep -rn 'agentColor\|agent-color' --include='*.sh' scripts/
# must match this file only.
#
# ── WHY THIS FILE EARNS ITS PLACE ────────────────────────────────────────────
# ABSENT/NULL SEMANTICS (three distinct outcomes, see cc_colour_normalise) and
# ERROR TRANSLATION (a value we cannot read becomes a logged non-opinion, never
# a crash and never a wrong colour). Ownership and precedence are POLICY and
# live in cc_tab_reconcile.sh; a policy decision landing here is a design error.
#
# bash 3.2.57 only: no associative arrays, no ${v,,}.

[ -n "${_CC_COLOUR_LOADED:-}" ] && return 0
_CC_COLOUR_LOADED=1

# ── Where the transcripts live ───────────────────────────────────────────────
# Overridable so tests never touch the user's real ~/.claude.
CC_PROJECTS_DIR="${CC_PROJECTS_DIR:-$HOME/.claude/projects}"

# ── How much of a transcript to read ─────────────────────────────────────────
# MEASURED on this machine's 4,896 transcripts: median 388 KB, p90 1.40 MB,
# p99 8.36 MB, max 655 MB. 1.1% are above 8 MB.
#
# The record is appended on every `/color`, so the newest one sits near EOF. A
# 200 KB tail window agreed with a full scan on 31/31 transcripts that carry a
# record — including a 13.8 MB one. That is the fast path, and it is the whole
# file whenever the file is small enough, so a small transcript is never read
# twice.
CC_COLOUR_TAIL_BYTES="${CC_COLOUR_TAIL_BYTES:-200000}"

# ── The fallback, and why it is BOUNDED ──────────────────────────────────────
# The tail window is a window, not the truth: a colour set early in a session
# that later wrote megabytes falls outside it. An empty window is therefore a
# MISS, not an answer, and the rest of the file has to be read.
#
# The brief costed that fallback at ~102 ms for the largest transcript. MEASURED
# here, it is not:
#
#     full awk scan of the 655 MB transcript   7,582 ms     (5 iterations)
#     tail-then-fallback on the same file      7,478 ms
#
# ~70x the estimate — and that file belongs to a LIVE session, so an unbounded
# fallback would stall a Stop hook for seven and a half seconds, every turn,
# for the 29 of 33 live sessions that have no colour record at all and can
# therefore never satisfy the fallback early.
#
# Two bounds make the fallback affordable without giving up the correctness it
# exists for:
#
#   1. A per-call CAP. At most CC_COLOUR_SCAN_MAX_BYTES are read in one call.
#      At the 8 MB default that is a full scan for 98.9% of transcripts, and the
#      last 8 MB for the rest.
#   2. An incremental WATERMARK CACHE (see _cc_colour_scan_deep). A transcript
#      is append-only, so bytes already scanned never change: what was read once
#      is never read again, and a colour found anywhere in the file is
#      remembered. Since the reconciler runs on every Stop hook, a `/color` is
#      seen in the tail window on the very next turn and then held for the life
#      of the session — which is the case the fallback was really for.
#
# The residual, stated plainly: a colour set in the first (size - 8 MB) bytes of
# a transcript that was ALREADY huge before this plugin first looked at it, and
# never set again, is not found. One log line records each time the cap bites.
CC_COLOUR_SCAN_MAX_BYTES="${CC_COLOUR_SCAN_MAX_BYTES:-8388608}"

# Re-read this much either side of the watermark. The boundary between two
# incremental reads lands mid-line, and a split record matches nothing; an
# agent-color record is ~95 bytes, so 4 KB of overlap is ~40 records of slack
# and costs nothing. Re-seeing a record is harmless: last-wins is idempotent.
CC_COLOUR_SCAN_OVERLAP="${CC_COLOUR_SCAN_OVERLAP:-4096}"

# A pure cache: losing it costs one escalated scan and nothing else. It lives
# beside the unknown-value stamps, under $TMPDIR, so a test never writes into a
# live plugin directory.
CC_COLOUR_CACHE_DIR="${CC_COLOUR_CACHE_DIR:-${TMPDIR:-/tmp}/tmux-cc-colour-scan}"

# shellcheck disable=SC2034
# The vocabulary this plugin publishes. `default` is a member: it is an opinion,
# not an absence. See cc_colour_normalise. Consumed by the scripts that SOURCE
# this library, never inside it.
CC_COLOUR_TOKENS="red orange yellow green cyan blue purple pink default"

# ── The scanner ──────────────────────────────────────────────────────────────
# One awk, not `grep | grep | tail`: awk does last-wins in END for free, and one
# fork matters when this runs per window on every Claude turn.
#
# It keys on BOTH `"type":"agent-color"` and a well-formed `"agentColor":"..."`.
# Requiring the type is what keeps a user MESSAGE that happens to discuss the
# field from being mistaken for one: inside a JSON string the quotes are
# escaped (\"type\":\"agent-color\"), so the literal cannot match.
#
# v is only ever ASSIGNED, never cleared. That is deliberate and it is the fix
# for an earlier bug class: a truncated final line — reachable, because Claude
# appends to this file continuously — must not blank a colour that several
# valid records already agreed on. An explicit "no colour" arrives as the STRING
# `default`, so nothing is lost by refusing to treat garbage as a clear.
# shellcheck disable=SC2016
# The $0/$-less awk source is single-quoted ON PURPOSE: `$0` and the regex
# below belong to awk, not to the shell.
_CC_COLOUR_SCAN_AWK='
  index($0, "\"type\":\"agent-color\"") == 0 { next }
  {
    if (match($0, /"agentColor"[ \t]*:[ \t]*"[^"]*"/)) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^"agentColor"[ \t]*:[ \t]*"/, "", s)
      sub(/"$/, "", s)
      v = s
    }
  }
  END { if (v != "") print v }'

# _cc_colour_scan <file> — the raw last-wins token, or "".
#
#   file <= tail window   ONE full scan. The window IS the file, so there is
#                         nothing to fall back to and the common case (no record
#                         at all) costs exactly one awk.
#   file >  tail window   The window first. A hit is the answer — it is the
#                         newest region of an append-only file. A miss escalates
#                         to _cc_colour_scan_deep.
_cc_colour_scan() {
  local f="$1" size out
  [ -f "$f" ] || return 0

  size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')"
  case "$size" in ''|*[!0-9]*) size=0 ;; esac

  if [ "$size" -le "$CC_COLOUR_TAIL_BYTES" ]; then
    printf '%s' "$(awk "$_CC_COLOUR_SCAN_AWK" "$f" 2>/dev/null)"
    return 0
  fi

  out="$(tail -c "$CC_COLOUR_TAIL_BYTES" "$f" 2>/dev/null | awk "$_CC_COLOUR_SCAN_AWK")"
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  _cc_colour_scan_deep "$f" "$size"
}

# _cc_colour_scan_deep <file> <size> — the bounded, incremental fallback.
#
# Cache entry, one line: "<bytes-scanned> <colour>". `bytes-scanned` is how much
# of THIS file has already been through the scanner; `colour` is the last token
# those bytes contained, or empty. Both halves matter: without the offset the
# big files are rescanned every turn, and without the remembered colour a
# `/color` that scrolls out of the tail window would be forgotten again.
#
# Every state transition is deliberate:
#   cache missing / unreadable   -> scan from 0 (capped)
#   scanned > size               -> the file was truncated or replaced under a
#                                   reused session id; the cache is about a
#                                   different file, so discard it entirely
#   scanned <= size              -> scan only [scanned - overlap, size)
#   backlog > cap                -> scan only the last <cap> bytes, and say so
#
# Reads and writes the cache with shell builtins only: no fork on the hot path,
# which is what makes a repeat call on a 655 MB transcript cost the same as one
# on a 600 KB one.
_cc_colour_scan_deep() {
  local f="$1" size="$2" key cache scanned colour start backlog out

  # Cache key from the path with no forks: <project-dir>__<sessionId>.jsonl.
  # Both components are single path elements already, so they are filename-safe.
  key="${f%/*}"; key="${key##*/}__${f##*/}"
  cache="$CC_COLOUR_CACHE_DIR/$key"

  scanned=0; colour=""
  if [ -r "$cache" ]; then
    read -r scanned colour < "$cache" 2>/dev/null || { scanned=0; colour=""; }
    case "$scanned" in ''|*[!0-9]*) scanned=0; colour="" ;; esac
    [ "$scanned" -gt "$size" ] && { scanned=0; colour=""; }
  fi

  start=$((scanned - CC_COLOUR_SCAN_OVERLAP))
  [ "$start" -lt 0 ] && start=0
  backlog=$((size - start))

  if [ "$backlog" -gt "$CC_COLOUR_SCAN_MAX_BYTES" ]; then
    start=$((size - CC_COLOUR_SCAN_MAX_BYTES))
    _cc_colour_log_once "cap:$key" \
      "cc_colour: $f is ${size}B with a ${backlog}B backlog — scanned the last ${CC_COLOUR_SCAN_MAX_BYTES}B only; a colour set before that point is not visible"
  fi

  if [ "$start" -le 0 ]; then
    out="$(awk "$_CC_COLOUR_SCAN_AWK" "$f" 2>/dev/null)"
  else
    # `tail -c +N` is 1-based: +1 is the whole file, so the offset needs +1.
    out="$(tail -c "+$((start + 1))" "$f" 2>/dev/null | awk "$_CC_COLOUR_SCAN_AWK")"
  fi
  [ -n "$out" ] && colour="$out"

  if mkdir -p "$CC_COLOUR_CACHE_DIR" 2>/dev/null; then
    printf '%s %s\n' "$size" "$colour" > "$cache" 2>/dev/null || true
  fi
  printf '%s' "$colour"
}

# ── Locating the transcript ──────────────────────────────────────────────────
# GLOB IS PRIMARY, and the computed slug is only ever a fast path that must
# prove itself by the file existing.
#
# MEASURED: the obvious rule (every non-alphanumeric byte in `cwd` becomes `-`)
# reproduces the real directory name for 2,828 of 2,950 transcripts — 95.86%.
# It is not 100%, and the 4% is not exotic:
#
#   * Some WORKTREE sessions are filed under the PARENT repo's directory
#     instead of their own path (`.../repo/.claude/worktrees/init` ->
#     `-Users-jack-dev-circl-coretechx-data-engine-demo`), while others keep the
#     full worktree path. The behaviour differs between Claude Code versions, so
#     NO cwd-derived rule can cover both. This user runs many worktree sessions.
#   * `cwd` is the process's CURRENT directory; the transcript is filed under
#     the directory the session STARTED in. A `cd` breaks the derivation.
#
# A wrong slug means a silently uncoloured tab, so correctness wins: glob for
# `<sessionId>.jsonl` under every project directory. The session id is a UUID,
# which makes the glob both unique and free of a directory-name rule.
#
# The slug fast path is kept only because a hit is SELF-VALIDATING — the file is
# either at that exact path or it is not — and it saves the readdir over ~356
# directories in the 96% case.
#
# `ls -t`/`stat` are avoided in the ambiguous case in favour of bash's `-nt`:
# four session ids on this machine exist in TWO project directories (a session
# resumed from another cwd), and the one still being appended to is the live
# answer.
cc_colour_transcript() {
  local sid="${1:-}" cwd="${2:-}" slug cand best f

  # The glob guard, not a style check: sid is interpolated into a path and into
  # a glob. A UUID is hex and dashes; anything else is refused outright rather
  # than allowed to reach the filesystem.
  case "$sid" in
    ''|*[!0-9A-Fa-f-]*) return 0 ;;
  esac
  [ -d "$CC_PROJECTS_DIR" ] || return 0

  # Fast path: the computed slug, accepted ONLY if the file is really there.
  if [ -n "$cwd" ]; then
    slug="$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')"
    cand="$CC_PROJECTS_DIR/$slug/$sid.jsonl"
    if [ -f "$cand" ]; then
      printf '%s' "$cand"
      return 0
    fi
  fi

  # Authoritative path: glob. An unmatched glob stays literal in bash, so every
  # candidate is existence-checked.
  best=""
  for f in "$CC_PROJECTS_DIR"/*/"$sid".jsonl; do
    [ -f "$f" ] || continue
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then
      best="$f"
    fi
  done
  [ -n "$best" ] && printf '%s' "$best"
  return 0
}

# ── cc_colour_for_session <sessionId> [cwd] ──────────────────────────────────
# The one call the reconciler makes. Returns a token from CC_COLOUR_TOKENS, or
# "" for "no opinion". Never fails, never prints to stdout anything but a token.
cc_colour_for_session() {
  local sid="${1:-}" cwd="${2:-}" path raw
  path="$(cc_colour_transcript "$sid" "$cwd")"
  [ -n "$path" ] || { printf ''; return 0; }
  raw="$(_cc_colour_scan "$path")"
  cc_colour_normalise "$raw"
}

# ── Unknown-value logging ────────────────────────────────────────────────────
# Logged ONCE per distinct value, not once per record: a schema change would
# otherwise put one line per live session into the log on every Claude turn.
# In-process memory handles the ~33 records of one run; the stamp directory
# handles the runs after that.
#
# Under $TMPDIR rather than ~/.config/tmux-claude so that (a) a test never has
# to write into a live plugin directory to exercise this path, and (b) the
# dedupe resets at reboot, which is the right cadence for "tell me again after
# an upgrade".
CC_COLOUR_STAMP_DIR="${CC_COLOUR_STAMP_DIR:-${TMPDIR:-/tmp}/tmux-cc-colour-seen}"
_CC_COLOUR_SEEN=""

# _cc_colour_log_once <dedupe-key> <message>
_cc_colour_log_once() {
  local dkey="$1" msg="$2" key stamp
  case "$_CC_COLOUR_SEEN" in *"<$dkey>"*) return 0 ;; esac
  _CC_COLOUR_SEEN="$_CC_COLOUR_SEEN<$dkey>"

  key="$(printf '%s' "$dkey" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)"
  stamp="$CC_COLOUR_STAMP_DIR/$key"
  if mkdir -p "$CC_COLOUR_STAMP_DIR" 2>/dev/null; then
    [ -e "$stamp" ] && return 0
    : > "$stamp" 2>/dev/null
  fi

  # _cc_log, not _cc_flog: the freeze log is the durable second copy of every
  # session id this feature kills for, and a cosmetic schema note does not
  # belong in it.
  if type -t _cc_log >/dev/null 2>&1; then
    _cc_log "$msg"
  else
    printf '%s\n' "$msg" >&2
  fi
}

# ── cc_colour_normalise <raw> ────────────────────────────────────────────────
# THREE OUTCOMES, AND THE DISTINCTION BETWEEN TWO OF THEM IS LOAD-BEARING:
#
#   no record            -> ""        NO OPINION. The reconciler leaves any
#                                     manual pin standing. This is ~99% of
#                                     sessions (2,961 of 2,991), which is
#                                     exactly why it must not be "default".
#   record we cannot read -> "" + log Same effect as absent — never a wrong
#                                     colour — and the raw value goes to the log
#                                     so a schema change is discoverable from a
#                                     `tail` rather than from a bug report.
#   agentColor: "default" -> "default"  AN OPINION THAT THERE IS NO COLOUR.
#
# "" and "default" MUST NOT be collapsed. If they were, every session that never
# ran `/color` — almost all of them — would out-vote a colour the human pinned
# by hand, and the pin would be erased on the next Stop hook.
cc_colour_normalise() {
  local raw="${1:-}" v

  # Fast path AND the common case: no record was found. Answer without forking.
  # Whitespace-only is indistinguishable from absent and is treated as absent.
  case "$raw" in *[![:space:]]*) ;; *) printf ''; return 0 ;; esac

  v="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]_-')"
  case "$v" in
    red|orange|yellow|green|cyan|blue|purple|pink) printf '%s' "$v" ;;
    default|none|normal|auto|off)                  printf 'default' ;;
    magenta)                                       printf 'pink' ;;     # plausible alias
    violet|mauve)                                  printf 'purple' ;;
    aqua|teal)                                     printf 'cyan' ;;
    # Anything else: a colour name Claude added that we do not carry, or an
    # encoding change. Degrade to no opinion and record it.
    *) _cc_colour_log_once "$raw" \
         "cc_colour: unrecognised agentColor '$raw' — ignored, tab left to the pin/default (schema change?)"
       printf '' ;;
  esac
}
